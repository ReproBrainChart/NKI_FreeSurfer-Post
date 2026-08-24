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


# Where the analysis folder is:
path_check_setup="/gpfs/fs001/cbica/projects/pennlinc_rbc/datasets/LINC_NKI/derivatives/freesurferpost-0-2-1-babs/analysis/code/check_setup"

# Fail whenever something is fishy, use -x to get verbose logfiles:
set -e -u -x

# NOTE: There is no input argument for this bash file.

# Change to a temporary directory
cd "/cbica/comp_space/pennlinc_rbc"

# Call `test_job.py`:
# get which python:
echo '# Call `test_job.py`:'
which_python=$(which python)
current_pwd=${PWD}
# call `test_job.py`:
echo 'Calling `test_job.py`...'
"${which_python}" "/gpfs/fs001/cbica/projects/pennlinc_rbc/datasets/LINC_NKI/derivatives/freesurferpost-0-2-1-babs/analysis/code/check_setup/test_job.py" --path-workspace "${PWD}" --path-check-setup "/gpfs/fs001/cbica/projects/pennlinc_rbc/datasets/LINC_NKI/derivatives/freesurferpost-0-2-1-babs/analysis/code/check_setup"

echo SUCCESS