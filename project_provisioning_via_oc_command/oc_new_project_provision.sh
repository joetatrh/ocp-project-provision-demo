#!/bin/bash

# check for mandatory binaries
for b in oc mktemp ; do
  if ! type ${b} &>/dev/null; then
    echo "$0: binary \"${b}\" not found; aborting"
    exit 1
  fi
done

# exit *immediately* on any failure (non-zero exit status)
set -e

# ensure presence of tempfile

function usage()
{
  cat <<-"EOF"
  $0: usage:
  $0 [-h] -e -t -n [-d] -g [-q] [-a annotation [ -a ... ]]
  where
    -h show this help
    -e OCP endpoint (oc whoami --show-server)
    -t OCP token (oc -n default sa get-token custom-project-provisioner)
    -n name of the project to create
    -d display name of the project
    -g LDAP group that owns this project
    -q initial size quota ({small,medium,large})
    -a is an annotation (-a my_annotation=my_value)
EOF
    exit 0
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

declare -a ANNOTATIONS

while getopts "e:t:n:d:g:q:a:" arg
do
  case "${arg}" in
  h)
    usage
    exit 0
  ;;
  e)
    export ENDPOINT="${OPTARG}"
  ;;
  t)
    export TOKEN="${OPTARG}"
  ;;
  n)
    export NAME="${OPTARG}"
  ;;
  d)
    export DISPLAY_NAME="${OPTARG}"
  ;;
  g)
    export GROUP_BASE="${OPTARG}"
  ;;
  q)
    export QUOTA="${OPTARG}"
  ;;
  a)
    ANNOTATIONS+=("${OPTARG}")
  ;;
  esac
done

# do not proceed if any mandatory arguments are absent
for mandatory_arg in ENDPOINT TOKEN NAME GROUP_BASE
do
  if [[ -z "${!mandatory_arg}" ]]; then
    echo "$0: mandatory argument \"${mandatory_arg}\" is missing; aborting"
    exit 1
  fi
done

function ocp_login()
{
  oc login --insecure-skip-tls-verify --token="${TOKEN}" "${ENDPOINT}" &>/dev/null
}

# ensure that we can log in to the OCP API using the provided credentials
if ! ocp_login
then
  echo "$0: failed logging in to OCP endpoint \"${ENDPOINT}\" ; aborting"
  exit 1
fi

# does the requested project already exist?
project_check="$(oc get project "${NAME}" --template='{{ .metadata.name }}' 2>/dev/null ||:)"
if [[ "${project_check}" == "${NAME}" ]]; then
  echo "$0: project \"${NAME}\" already exists; aborting"
  exit 1
fi

# create the project
oc new-project "${NAME}" --display-name="${DISPLAY_NAME:-$NAME}" &>/dev/null

# apply the requested annotations to the project
if [[ ${#ANNOTATIONS[@]} -gt 0 ]]
then
  for i in $(seq 0 $(( ${#ANNOTATIONS[@]} -1 )) )
  do
    oc annotate namespace "${NAME}" "${ANNOTATIONS[${i}]}" &>/dev/null
  done
fi

# bind the {admin,edit,view} roles to the project
# we assume that there exist in LDAP groups with names like:
#  (openshift|ocp|ose).*-(admin|edit|view)
oc adm policy add-role-to-group admin "${GROUP_BASE}-admin" -n "${NAME}" &>/dev/null
oc adm policy add-role-to-group edit "${GROUP_BASE}-edit" -n "${NAME}" &>/dev/null
oc adm policy add-role-to-group view "${GROUP_BASE}-view" -n "${NAME}" &>/dev/null

# create resource constraints
case "${QUOTA}" in
  medium)
    quotafile="limit-and-quota-medium.yaml"
  ;;
  large)
    quotafile="limit-and-quota-large.yaml"
  ;;
  *|small)
    quotafile="limit-and-quota-small.yaml"
  ;;
esac
oc process -f ./${quotafile} | oc apply -n "${NAME}" -f - &>/dev/null
