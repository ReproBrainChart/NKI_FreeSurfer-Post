#!/bin/bash
# =============================================================================
# Per-unit publication job. Invoked by submit_array.sh as one SLURM array task.
# Clones the analysis dataset, prepares one zipped subject-session or one
# already-unzipped BIDS subject, pushes its files to fcp-indi (S3), and pushes
# the result branch to the output RIA store.
#
#   Args: <dssource> <pushgitremote> <subses-or-subject> <dslockfile> [layout]
#
# A result branch reaches the output RIA only on full success. Partial S3 uploads
# are safe because git-annex content is content-addressed and retryable; the
# branch push is the final success marker that find_missing.sh looks for.
# =============================================================================
set -e -u -x

dssource="$1"       # input RIA URL to clone the analysis dataset from
pushgitremote="$2"  # output RIA git URL to push the result branch to
subses="$3"         # e.g. sub-1234_ses-1 (zip) or sub-1234 (BIDS)
DSLOCKFILE="$4"     # shared lock file serializing git pushes
INPUT_LAYOUT="${5:-zip}"
FORCE_UPLOAD_PATHS="${FORCE_UPLOAD_PATHS:-}"

case "${INPUT_LAYOUT}" in
    zip|bids)
        ;;
    *)
        echo "ERROR: unsupported input layout: ${INPUT_LAYOUT}" 1>&2
        exit 1
        ;;
esac

# Load fcp-indi credentials before the clone so the S3 remote auto-enables.
# (load_credentials.sh disables xtrace while decoding so secrets never reach
# the SLURM log files.)
# shellcheck disable=SC1091
source code/load_credentials.sh || exit 1

# Work in shared comp_space instead of node-local scratch.
JOB_WORKDIR="${TMPDIR}"
mkdir -p "${JOB_WORKDIR}"
cd "${JOB_WORKDIR}"
BRANCH="job-${SLURM_ARRAY_JOB_ID}-${SLURM_ARRAY_TASK_ID}-${subses}"

cleanup() {
    set +e
    jobdir="${JOB_WORKDIR:?}/${BRANCH:?}"
    cd "${JOB_WORKDIR}" 2>/dev/null || true
    rm -rf "${jobdir}" 2>/dev/null
    if [ -e "${jobdir}" ]; then
        # git-annex protects object directories, including in subdatasets; make
        # job directories removable, then retry workdir cleanup.
        find "${jobdir}" -type d -exec chmod u+rwx {} + 2>/dev/null || true
        rm -rf "${jobdir}" 2>/dev/null || true
        if [ -e "${jobdir}" ]; then
            echo "WARNING: workdir cleanup incomplete: ${jobdir}" 1>&2
        fi
    fi
}
trap cleanup EXIT

# Return the annex UUID for fcp-indi. This UUID is needed when repairing local
# presence records after direct S3 probes.
get_fcpindi_remote_uuid() {
    local remote_uuid

    remote_uuid=$(git config --get remote.fcp-indi.annex-uuid || true)
    if [ -z "${remote_uuid}" ]; then
        echo "ERROR: could not find annex UUID for fcp-indi." 1>&2
        return 1
    fi
    printf '%s\n' "${remote_uuid}"
}

# Probe fcp-indi directly for every annexed key in this job clone. Unlike
# `git annex find --not --in`, checkpresentkey asks the special remote whether
# the object is actually available, so stale presence records cannot mask a
# failed upload.
probe_fcpindi_content() {
    local present_batch_file="$1"
    local missing_file="$2"
    local probe_errors_file="$3"
    local check_stderr_file remote_uuid key path status

    remote_uuid=$(get_fcpindi_remote_uuid)
    : > "${present_batch_file}"
    : > "${missing_file}"
    : > "${probe_errors_file}"
    check_stderr_file="${probe_errors_file}.check"

    # shellcheck disable=SC2016
    while IFS=$'\t' read -r key path; do
        if [ -z "${path}" ]; then
            continue
        fi
        if [ -z "${key}" ]; then
            printf '%s\n' "${path}" >> "${probe_errors_file}"
            continue
        fi

        : > "${check_stderr_file}"
        if git annex checkpresentkey "${key}" fcp-indi >/dev/null 2>"${check_stderr_file}"; then
            printf '%s %s 1\n' "${key}" "${remote_uuid}" >> "${present_batch_file}"
        else
            status=$?
            if [ "${status}" -eq 1 ]; then
                printf '%s\n' "${path}" >> "${missing_file}"
            else
                cat "${check_stderr_file}" >> "${probe_errors_file}"
                printf '%s\t%s\tcheckpresentkey exited %s\n' "${path}" "${key}" "${status}" >> "${probe_errors_file}"
            fi
        fi
    done < <(git annex find --format='${key}\t${file}\n')
    rm -f "${check_stderr_file}"

    if [ -s "${present_batch_file}" ]; then
        git annex setpresentkey --batch < "${present_batch_file}"
    fi
}

# Re-upload one annexed file to fcp-indi and prove the key exists on S3 before
# returning success. The absent mark prevents git-annex from skipping the copy
# because of stale presence metadata.
upload_fcpindi_path_with_probe() {
    local path="$1"
    local remote_uuid="$2"
    local key

    key=$(git annex lookupkey -- "${path}" || true)
    if [ -z "${key}" ]; then
        echo "ERROR: cannot repair ${path}; it is not an annexed file." 1>&2
        return 1
    fi
    if [ -z "$(git annex find --in here -- "${path}")" ]; then
        echo "ERROR: cannot repair ${path}; content is not present in this job clone." 1>&2
        return 1
    fi

    git annex setpresentkey "${key}" "${remote_uuid}" 0
    if ! git annex copy --to fcp-indi -- "${path}"; then
        echo "ERROR: git annex copy failed for ${path}." 1>&2
        return 1
    fi
    if ! git annex checkpresentkey "${key}" fcp-indi; then
        echo "ERROR: fcp-indi still does not provide ${path} after copy." 1>&2
        return 1
    fi
    git annex setpresentkey "${key}" "${remote_uuid}" 1
}

# Verify that this job's annexed outputs are present on fcp-indi. This does not
# trust local annex presence records: every key is directly probed on S3. If the
# first probe finds missing content, retry only those files from the local job
# clone, then verify once more before the result branch is allowed to publish.
verify_fcpindi_content() {
    local fsck_status verify_dir present_batch_file missing_file probe_errors_file
    local remote_uuid retry_failed path

    fsck_status=0
    # fsck checks the remote's annex location records/availability. Capture its
    # status for diagnostics, but direct probes below are the source of truth.
    git annex fsck --fast -f fcp-indi || fsck_status=$?

    verify_dir=$(mktemp -d .git/fcpindi-verify.XXXXXX)
    present_batch_file="${verify_dir}/present.batch"
    missing_file="${verify_dir}/missing.txt"
    probe_errors_file="${verify_dir}/probe-errors.txt"

    probe_fcpindi_content "${present_batch_file}" "${missing_file}" "${probe_errors_file}"
    if [ "${fsck_status}" -eq 0 ] && [ ! -s "${missing_file}" ] && [ ! -s "${probe_errors_file}" ]; then
        rm -rf "${verify_dir}"
        return 0
    fi

    echo "WARNING: fcp-indi verification failed for ${subses}; retrying missing content." 1>&2
    if [ -s "${probe_errors_file}" ]; then
        echo "ERROR: direct fcp-indi probe errors:" 1>&2
        cat "${probe_errors_file}" 1>&2
    fi

    remote_uuid=$(get_fcpindi_remote_uuid)
    retry_failed=0
    if [ -s "${missing_file}" ]; then
        cat "${missing_file}" 1>&2
        while IFS= read -r path; do
            if [ -z "${path}" ]; then
                continue
            fi
            if ! upload_fcpindi_path_with_probe "${path}" "${remote_uuid}"; then
                retry_failed=1
            fi
        done < "${missing_file}"
    fi
    if [ "${retry_failed}" -ne 0 ] || [ -s "${probe_errors_file}" ]; then
        rm -rf "${verify_dir}"
        return 1
    fi

    # The retry must leave both direct S3 probes and fsck clean. If not, fail
    # before pushing the result branch so this session can be resubmitted.
    probe_fcpindi_content "${present_batch_file}" "${missing_file}" "${probe_errors_file}"
    if [ -s "${missing_file}" ] || [ -s "${probe_errors_file}" ]; then
        echo "ERROR: content still missing or unverifiable on fcp-indi after retry:" 1>&2
        cat "${missing_file}" "${probe_errors_file}" 1>&2
        rm -rf "${verify_dir}"
        return 1
    fi
    git annex fsck --fast -f fcp-indi
    rm -rf "${verify_dir}"
}

# Optional repair mode for stale fcp-indi annex location records. FORCE_UPLOAD_PATHS
# points to a newline-delimited path list; only paths for this job's subject-session
# are handled. Each matching key is first marked absent from fcp-indi so git-annex
# cannot skip the upload because of stale presence metadata.
force_upload_listed_fcpindi_content() {
    local remote_uuid matched failed path

    if [ -z "${FORCE_UPLOAD_PATHS}" ]; then
        return 0
    fi
    if [ ! -s "${FORCE_UPLOAD_PATHS}" ]; then
        echo "ERROR: FORCE_UPLOAD_PATHS is empty or unreadable: ${FORCE_UPLOAD_PATHS}" 1>&2
        return 1
    fi

    remote_uuid=$(get_fcpindi_remote_uuid)

    matched=0
    failed=0
    while IFS= read -r path; do
        if [ -z "${path}" ] || ! printf '%s\n' "${path}" | grep -Fq "${subses}"; then
            continue
        fi

        matched=$((matched + 1))
        if ! upload_fcpindi_path_with_probe "${path}" "${remote_uuid}"; then
            failed=1
        fi
    done < "${FORCE_UPLOAD_PATHS}"

    if [ "${matched}" -eq 0 ]; then
        echo "ERROR: no FORCE_UPLOAD_PATHS entries matched ${subses}." 1>&2
        return 1
    fi
    if [ "${failed}" -ne 0 ]; then
        echo "ERROR: force-upload failed for one or more ${subses} paths." 1>&2
        return 1
    fi

    echo "Force-uploaded ${matched} ${subses} path(s) to fcp-indi."
}

mkdir "${BRANCH}"
cd "${BRANCH}"

# Clone the analysis dataset from the INPUT store (not the push target, to
# avoid a throughput bottleneck on the output store).
datalad clone "${dssource}" ds
cd ds
git remote add outputstore "${pushgitremote}"
git checkout -b "${BRANCH}"

# Install the input subdataset (git tree only), then fetch and prepare only this
# job's publication unit.
datalad get -n inputs/data
case "${INPUT_LAYOUT}" in
    zip)
        ZIP=$(find inputs/data -name "${subses}_*.zip" | head -n 1)
        if [ -z "${ZIP}" ]; then
            echo "ERROR: no zip found for ${subses} under inputs/data" 1>&2
            exit 1
        fi
        datalad get "${ZIP}"

        # Unzip + rename + de-duplicate, recorded as provenance.
        datalad run -m "unzip ${subses}" "bash code/get_files.sh ${ZIP}"
        ;;
    bids)
        if ! printf '%s\n' "${subses}" | grep -Eq '^sub-[A-Za-z0-9]+$'; then
            echo "ERROR: invalid BIDS subject directory name: ${subses}" 1>&2
            exit 1
        fi
        subject_source="inputs/data/${subses}"
        if [ ! -d "${subject_source}" ]; then
            echo "ERROR: BIDS subject directory not found: ${subject_source}" 1>&2
            exit 1
        fi

        # Fetch every annexed file below this subject, dereference the source
        # annex symlinks into the output dataset, and annex the copied tree.
        # No other source path is copied.
        datalad get -r "${subject_source}"
        cp -RL -- "${subject_source}" .
        datalad save -m "Copy ${subses} BIDS data without extraction" -- "${subses}"
        ;;
esac

# Push file CONTENT to S3 first -- no lock needed, content writes don't conflict.
# A transient partial failure is repaired/validated below; only the final
# verification result decides whether the success branch can be pushed.
push_status=0
datalad push --to fcp-indi || push_status=$?
if [ "${push_status}" -ne 0 ]; then
    echo "WARNING: datalad push to fcp-indi exited ${push_status}; verifying and retrying missing content." 1>&2
fi
force_upload_listed_fcpindi_content
# If content is still missing, exit before the branch push so find_missing.sh
# can resubmit this publication unit. Partial S3 uploads are safe: annex keys are
# content-addressed, so retries reuse existing keys and upload only misses.
verify_fcpindi_content

# Push the result BRANCH second -- locked, to serialize git ref updates. Once
# this succeeds, find_missing.sh considers the publication unit complete.
flock "${DSLOCKFILE}" git push outputstore "${BRANCH}"

echo "SUCCESS ${subses}"
# Scratch clone is removed by the EXIT trap.
