#!/bin/bash
# =============================================================================
# get_files variant: freesurfer-post
#
# Unzip ONE BABS-produced FreeSurfer-post archive into the dataset root,
# preserving the filenames produced by FreeSurfer-post.
#
# Invoked by participant_job.sh inside `datalad run`. CWD is the dataset root.
#   Argument $1: path to the .zip file (under inputs/data/).
# =============================================================================
set -e -u -x

ZIP_FILE="$1"
zipbase=$(basename "${ZIP_FILE}")
subid=$(echo "${zipbase}" | grep -oE 'sub-[A-Za-z0-9]+' | head -n 1)
sesid=$(echo "${zipbase}" | grep -oE 'ses-[A-Za-z0-9]+' | head -n 1)

if [ -z "${subid}" ] || [ -z "${sesid}" ]; then
    echo "ERROR: expected both sub-* and ses-* in freesurfer-post zip name: ${zipbase}" 1>&2
    exit 1
fi

# For sub-X_ses-Y_freesurfer-post-0-1-2.zip, the zip's top-level folder is
# "freesurfer-post".
LEADING_DIR="freesurfer-post"

# --- extract -----------------------------------------------------------------
move_tree_no_overwrite() {
    local src_dir="$1"
    local dst_dir="$2"
    local src name dst

    shopt -s nullglob dotglob
    mkdir -p "${dst_dir}"
    for src in "${src_dir}"/*; do
        name=$(basename "${src}")
        dst="${dst_dir}/${name}"

        if [ -d "${src}" ] && [ ! -L "${src}" ] && [ -d "${dst}" ] && [ ! -L "${dst}" ]; then
            move_tree_no_overwrite "${src}" "${dst}"
            rmdir "${src}"
        elif [ -e "${dst}" ]; then
            echo "ERROR: refusing to overwrite existing path: ${dst}" 1>&2
            return 1
        else
            mv "${src}" "${dst}"
        fi
    done
}

extract_dir=$(mktemp -d "${PWD}/.get_files_extract.XXXXXX")
cleanup_extract() {
    rm -rf "${extract_dir}"
}
trap cleanup_extract EXIT

unzip -q "${ZIP_FILE}" -d "${extract_dir}"
if [ ! -d "${extract_dir}/${LEADING_DIR}" ]; then
    echo "ERROR: leading dir '${LEADING_DIR}/' not found in ${zipbase}." 1>&2
    echo "       Run '7z l ${ZIP_FILE}' and fix LEADING_DIR in code/get_files.sh." 1>&2
    exit 1
fi

# Lift the contents up to the dataset root without replacing any existing file.
move_tree_no_overwrite "${extract_dir}/${LEADING_DIR}" "."

echo "get_files.freesurfer-post: unpacked ${zipbase}"
