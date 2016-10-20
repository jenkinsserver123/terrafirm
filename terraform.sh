#!/bin/bash

# Written by: https://github.com/GuitarrasDeAmor
# This is a wrapper script for Terraform that allows us to have separate state files per environment and internal module.

# Help options http://tuxtweaks.com/2014/05/bash-getopts/
# Set Script Name variable
SCRIPT=`basename ${BASH_SOURCE[0]}`

# Set fonts for Help.
NORM=`tput sgr0`
BOLD=`tput bold`
REV=`tput smso`

# Help function
function HELP {
  echo -e \\n"Help documentation for ${BOLD}${SCRIPT}.${NORM}"\\n
  echo -e "${REV}Basic usage:${NORM} ${BOLD}$SCRIPT (action) (environment) (module) (extra_args)${NORM}"\\n
  echo "Command line switches are optional. The following switches are recognized:"
  echo -e "${REV}-h${NORM}  --Displays this help message. No further functions are performed."\\n
  echo "Command line options:"
  echo -e "${REV}\$1${NORM} (Required) Argument to pass action to Terraform."
  echo -e "${REV}\$2${NORM} (Required) Argument to pass environment to run Terraform in."
  echo -e "${REV}\$3${NORM} (Required) Argument to pass module to create to Terraform."
  echo -e "${REV}\$4${NORM} (Optional) Argument to pass extra CLI arguments to Terraform."
  echo -e "Example: ${BOLD}$SCRIPT plan dev microservice -target=resource${NORM}"\\n
  exit 1
}

# Check the number of arguments. If none are passed, print help and exit.
NUMARGS=$#
if [ $NUMARGS -eq 0 ]; then
  HELP
fi

while getopts :h FLAG; do
  case $FLAG in
    h)  # Show help
      HELP
      ;;
    \?) # Unrecognized option - show help
      echo -e "Use ${BOLD}$SCRIPT -h${NORM} to see the help documentation."\\n
      exit 2
      ;;
  esac
done

# Set environment variables for Terraforming
action=$1
environment=$2
module=$3
s3_bucket="your-terraform-state-bucket"
aws_profile="default"
extra_args=$4

# Make sure the user is in the root directory of the terraform repo.
if [ "${PWD##*/}" != "infrastructure" ]; then
	echo "You need to be in the root of the Terraform project."
	exit 1
fi

# Make sure the user has a valid .aws directory; if not, ask them to create it.
ls .aws &>/dev/null
check_aws_dir=`echo $?`
if [ "${check_aws_dir}" -ne 0 ]; then
	echo -e "${REV}ERROR:${NORM} It appears you do not have your AWS credentials available at '$(pwd)/.aws'.\n\n Please symlink your '$HOME/.aws' directory to '$(pwd)/.aws' with the following command.\n    ln -s $HOME/.aws $(pwd)/.aws"
	exit 1
fi

# Check the action argument to see if it calls an actual terraform action.
if [ "${action}" != 'plan' ] && [ "${action}" != 'apply' ] && [ "${action}" != 'destroy' ]; then
	echo "Specify whether you want to plan, apply, or destroy an environment."
	exit 1
fi

# Check the environment argument to see if it calls a real environment.
if [ "${environment}" != "dev" ] && [ "${environment}" != "stage" ] && [ "${environment}" != "prod" ]; then
	echo "You need to specify an environment."
	exit 1
fi

# Check the module to make sure we actually specified one.
if [ "${module}" == "" ]; then
	echo "You need to specify an internal module to build."
	exit 1
else
	# Try to cd into the module directory; if it doesn't exist, then stop the script.
	cd modules/internal/${module}/ &>/dev/null
	check_module_exists=`echo $?`
  if [ "${check_module_exists}" -ne 0 ]; then
	  echo "Are you sure this module exists? Cannot find the module at $(pwd)/modules/internal/${module}/"
	  exit 1
	fi
fi

# Check for extra_args; if they exist, make sure they are prefixed with a hyphen.
if [ "${extra_args}" != "" ] && [[ "${extra_args}" != -* ]]; then
	echo "The extra arguments option allows you to use more Terraform options if necessary. The CLI options should start with '-'."
	exit 1
fi

# Gather any modules necessary; if the modues cannot be found, stop here.
terraform get
check_get=`echo $?`
if [ "${check_get}" -ne 0 ]; then
	echo -e "${REV}Fix the module download issues above, then re-run this script.${NORM}"
	exit 1
fi

# Validate configuration; if validation fails, stop here.
terraform validate
check_validation=`echo $?`
if [ "${check_validation}" -ne 0 ]; then
	echo -e "${REV}Fix the validation errors above, then re-run this script.${NORM}"
	exit 1
fi

# Create a graph and place it in the .terraform folder if the user has DOT installed
dot -? &>/dev/null
check_dot=`echo $?`
if [ "${check_dot}" -eq 0 ]; then
  terraform graph -draw-cycles | dot -Tpng > .terraform/${module}.png
  echo -e "${REV}Notice:${NORM} A visual graph of your execution has been created for this module. View it with the command below:\n    open $(pwd)/.terraform/${module}.png\n"
else
	echo -e "${REV}Notice:${NORM}If you want visual representations of your Terraform execution, install Graphviz. To install on a Mac, run the command below:\n    brew install graphviz\n"
fi

# Remove any local terraform.tfstate files
# If you are working in one environment, and switch to another, these files will get copied up if not deleted
# We will not remove the terraform.tfstate.lock if it is there, as that could cause problems.
echo -e "${REV}Notice:${NORM} Removing terraform.tfstate files currently in place..."
rm .terraform/terraform.tfstate
rm .terraform/terraform.tfstate.backup

# Check for a lock file; if it exists, warn the user. If not, create it.
aws --profile ${aws_profile} s3 ls s3://${s3_bucket}/${environment}/${module}/terraform.tfstate.lock
check_s3_lock_exists=`echo $?`
if [ "${check_s3_lock_exists}" -eq 0 ]; then
	echo -e "${REV}ERROR:${NORM} There is a remote lock file in place. Somebody else could be Terraforming right now. Check with your team.\n\n${REV}WARNING:${NORM} Removing the lock file manually could result in corrupted state files.\n\n${REV}DO NOT REMOVE THIS FILE MANUALLY unless you are ABSOLUTELY SURE you will NOT mess up the tfstate file.${NORM}"
  exit 1
fi
ls "$(pwd)/.terraform/terraform.tfstate.lock" &>/dev/null
check_local_lock_exists=`echo $?`
if [ "${check_local_lock_exists}" -eq 0 ]; then
	echo -e "${REV}WARNING:${NORM} There is a local lock file in place, however there appears to be no remote lock file in place.\nIf you believe this warning to be in error, execute the command below and re-run this script.\n    rm $(pwd)/.terraform/terraform.tfstate.lock"
	exit 1
else
	echo -e "No lock file present. Creating lock file..."\\n
	echo -e "Terraform is currently working. DO NOT REMOVE THIS LOCK FILE MANUALLY.\nLock file placed on $(date)" > .terraform/terraform.tfstate.lock
	echo "Uploading lock file to S3..."
	aws --profile ${aws_profile} s3 cp .terraform/terraform.tfstate.lock s3://${s3_bucket}/${environment}/${module}/terraform.tfstate.lock
	sleep 5
fi

# Setup the Terraform remote configuration in the specified S3 bucket separated by environment and internal module.
terraform remote config -backend=s3 -backend-config="bucket=${s3_bucket}" -backend-config="region=us-east-1" \
-backend-config="shared_credentials_file=../../../.aws/credentials" -backend-config="profile=${aws_profile}" \
-backend-config="key=${environment}/${module}/terraform.tfstate"

# Run the Terraform action.
terraform ${action} -var-file ../../../variables/${environment}.tfvars ${extra_args}

# Remove the lock file locally and remotely
echo -e "Terraform is finished running. Removing lock file from S3..."
sleep 5
aws --profile ${aws_profile} s3 rm s3://${s3_bucket}/${environment}/${module}/terraform.tfstate.lock
echo -e \\n"Removing local lock file..."
rm .terraform/terraform.tfstate.lock
