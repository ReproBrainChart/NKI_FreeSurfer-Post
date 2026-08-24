#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=10G
#SBATCH --propagate=NONE

#SBATCH --time=02:00:00
#SBATCH --tmp=10G

# shellcheck disable=SC1091
source /cbica/projects/pennlinc_rbc/miniforge3/bin/activate babs


# Fail whenever something is fishy, use -x to get verbose logfiles:
set -e -u -x

# Inputs of the bash script:
dssource="$1"	# i.e., `input_ria`
pushgitremote="$2"	# i.e., `output_ria`
SUBJECT_CSV="$3"

subject_row=$(head -n $((SLURM_ARRAY_TASK_ID + 1)) "${SUBJECT_CSV}" | tail -n 1)
subid=$(echo "$subject_row" | python -c "import sys, re; pattern = r'sub-[a-zA-Z0-9]+(?=,|$)'; matches = re.findall(pattern, sys.stdin.read()); print(matches[0] if len(matches) == 1 else 'ERROR')")
sesid=$(echo "$subject_row" | python -c "import sys, re; pattern = r'ses-[a-zA-Z0-9]+(?=,|$)'; matches = re.findall(pattern, sys.stdin.read()); print(matches[0] if len(matches) == 1 else 'ERROR')")

# Change to a temporary directory
cd "/cbica/comp_space/pennlinc_rbc"
JOB_SCRATCH_DIR="$(pwd)"

# Setup: ---------------------------------------------------------------
# set up the branch:
echo '# Branch name (also used as temporary directory):'
BRANCH="job-${SLURM_ARRAY_JOB_ID}-${SLURM_ARRAY_TASK_ID}-${subid}-${sesid}"

cleanup() {
  set +e
  if [ -d "${JOB_SCRATCH_DIR:?}/${BRANCH:?}/ds" ]; then
    cd "${JOB_SCRATCH_DIR:?}/${BRANCH:?}/ds" 2>/dev/null || true
    datalad drop -r . --reckless availability --reckless modification >/dev/null 2>&1 || true
    git annex dead here >/dev/null 2>&1 || true
  fi
  cd "${JOB_SCRATCH_DIR:?}" 2>/dev/null || true
  rm -rf "${JOB_SCRATCH_DIR:?}/${BRANCH:?}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir "${BRANCH}"
cd "${BRANCH}"

# datalad clone the input ria:
echo '# Clone the data from input RIA:'
datalad clone "${dssource}" ds -- --no-checkout
cd ds

# set up the result deposition:
echo '# Register output RIA as remote for result deposition:'
git remote add outputstore "${pushgitremote}"

# set up a new branch:
echo "# Create a new branch for this job's results:"
git checkout -b "${BRANCH}"

# always use sparse-checkout, print error when not available
if ! git sparse-checkout init --cone; then
    echo "ERROR: git sparse-checkout is not available (or failed to initialize) on this system." 1>&2
    exit 1
fi

git sparse-checkout set \
  code \
  containers \
  inputs/data/fmriprep_anat
git checkout -f

# Start of the application-specific code: ------------------------------

# pull down only needed session path and explicit dataset-level metadata:
echo "# Pull down the input session but don't retrieve data contents:"

# resolve_tier lists the files of ONE directory tier of an input subdataset.
# git ls-tree reads the committed tree (independent of sparse/checkout state) and is
# non-recursive, so it is anchored to the named tier and never descends into other
# subjects. In valid BIDS no data files sit at the dataset root or directly under
# sub-XX/, so every blob at those tiers is BIDS-inherited metadata (task/modality
# .json sidecars, participants/sessions .tsv, .bval/.bvec, ...). We resolve to literal
# paths because `datalad get`/`git sparse-checkout` cannot take a glob.
resolve_tier() {  # $1 = subdataset path, $2 = tier dir relative to its root ('' = root)
  git -C "$1" ls-tree HEAD ${2:+"$2/"} 2>/dev/null | awk '$2 == "blob" { sub(/^[^\t]*\t/, ""); print }'
}

DATALAD_INPUTS=()
datalad get -n "inputs/data/fmriprep_anat"

# shellcheck disable=SC1091
find_single_zip_in_git_tree() {
  local zip_search_path="$1"
  local name="$2"
  local hits count

  # Match each identifier as a FIXED string: derivative names can contain regex
  # metacharacters (e.g. the '+' and '.' in 'fMRIPrep-25.2.5+anat'), which broke
  # the previous single `grep -E`. Only the .zip suffix is a genuine anchor.
  hits="$(
    git -C "${zip_search_path}" ls-tree -r --name-only HEAD \
      | grep -F "${subid}" | grep -F "${sesid}" | grep -F "${name}" | grep -E '\.zip$' \
      || true
  )"

  count="$(printf "%s\n" "${hits}" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "${count}" -ne 1 ]; then
    echo "ERROR: Expected exactly 1 matching ${name} zip in ${zip_search_path}, found ${count}" 1>&2
    printf "%s\n" "${hits}" 1>&2
    exit 1
  fi

  printf "%s/%s\n" "${zip_search_path}" "${hits}"
}

FMRIPREP_ANAT_ZIP="$(find_single_zip_in_git_tree inputs/data/fmriprep_anat fmriprep_anat)"
echo 'found fmriprep_anat zipfile:'
echo "${FMRIPREP_ANAT_ZIP}"


# Link shared container image(s) so each job does not re-clone the same image.
CONTAINER_IMAGE_PATHS=(
  "containers/.datalad/environments/freesurferpost-0-2-1/image"
)

for CONTAINER_JOB in "${CONTAINER_IMAGE_PATHS[@]}"; do
  CONTAINER_SHARED="/gpfs/fs001/cbica/projects/pennlinc_rbc/datasets/LINC_NKI/derivatives/freesurferpost-0-2-1-babs/analysis/${CONTAINER_JOB}"

  if [ ! -e "${CONTAINER_SHARED}" ] && [ ! -L "${CONTAINER_SHARED}" ]; then
    echo "ERROR: shared container image not found at ${CONTAINER_SHARED}" >&2
    exit 1
  fi

  mkdir -p "$(dirname "${CONTAINER_JOB}")"
  rm -f "${CONTAINER_JOB}"
  ln -s "${CONTAINER_SHARED}" "${CONTAINER_JOB}" || exit 1

  if [ ! -L "${CONTAINER_JOB}" ]; then
    echo "ERROR: failed to create symlink ${CONTAINER_JOB}" >&2
    exit 1
  fi
done

# datalad run:
datalad run \
	-i "code/freesurferpost-0-2-1_zip.sh" \
	-i "${FMRIPREP_ANAT_ZIP}" \
	${DATALAD_INPUTS[@]+"${DATALAD_INPUTS[@]}"} \
	-i "containers/.datalad/environments/freesurferpost-0-2-1/image" \
	--explicit \
	-o "${subid}_${sesid}_freesurfer-post-0-2-1.zip" \
	-m "freesurferpost-0-2-1 ${subid} ${sesid}" \
    "bash ./code/freesurferpost-0-2-1_zip.sh ${subid}  ${sesid} ${FMRIPREP_ANAT_ZIP}"

# Finish up:
# push result file content to output RIA storage:
echo '# Push result file content to output RIA storage:'
datalad push --to output-storage

# push the output branch:
echo '# Push the branch with provenance records:'
# DSLOCKFILE set by sbatch --export= in container.py
# shellcheck disable=SC2154
flock "${DSLOCKFILE}" git push outputstore "${BRANCH}"

echo SUCCESS