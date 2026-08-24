#!/bin/bash
set -e -u -x

subid="$1"
sesid="$2"
FMRIPREP_ANAT_ZIP="$3"

wd=${PWD}
cd inputs/data/fmriprep_anat
ZIPNAME=$(basename "${FMRIPREP_ANAT_ZIP}")
7z x "${ZIPNAME}"
cd "$wd"

mkdir -p "${PWD}/.git/tmp/wkdir"

mkdir -p "outputs/freesurfer-post"
singularity run \
    -B "${PWD}" \
    -B "/cbica/projects/pennlinc_rbc/apptainer/license.txt":"/SGLR/FREESURFER_HOME/license.txt" \
    --cleanenv \
    --containall \
    --writable-tmpfs \
    --pwd "${PWD}/.git/tmp/wkdir" \
    "containers/.datalad/environments/freesurferpost-0-2-1/image" \
        "${PWD}/inputs/data/fmriprep_anat/fmriprep_anat" \
        "${PWD}/outputs/freesurfer-post" \
        participant \
        --session-id $sesid \
        -w "${PWD}/.git/tmp/wkdir" \
        --fs-license-file /SGLR/FREESURFER_HOME/license.txt \
        --subjects-dir ${PWD}/inputs/data/fmriprep_anat/fmriprep_anat/sourcedata/freesurfer \
        --subject-id "${subid}"

cd outputs
7z a ../"${subid}_${sesid}_freesurfer-post-0-2-1.zip" "freesurfer-post"
cd ..
rm -rf outputs .git/tmp/wkdir
