#!/bin/bash

if ! oc whoami &>/dev/null
then
	1>&2 echo "$0: this prototype requires that you be logged in to \"oc\" before running"
	exit 1
fi

PROJECT_NAME="foo-project"
PROJECT_DISPLAY_NAME="this is the foo-project project"
QUOTA_SIZE="small"

# get the first token associated with the "custom-project-provisioner" serviceaccount.
# for real use in ServiceNow, this token would be stored somewhere;
# it wouldn't be determined at runtime.
TOKEN=$(oc -n default serviceaccounts get-token custom-project-provisioner)

# the public hostname of the OCP master API server, with any leading "https://" removed
# again, this should not be determined at runtime; it should be stored somewhere
ENDPOINT=$(oc whoami --show-server | sed -r -e 's;^https?://;;g')

# BACKGROUND: To provision a new project in OpenShift, we're effectively
# doing nothing more than creating a series of objects inside the OCP API.
# Use commands like "oc explain foo" or "oc create foo ... -o yaml" (or even
# just look at YAML definitions inside the web console) to see what these
# objects look like.  Use "oc explain foo" to get the API path for each object.

# PUT an object into the OCP API at the given path
function ocp_curl_put()
{
	object="$1"
	apipath="$2"

	echo "${object}" |
	curl -k \
	-X POST \
	-d @- \
	-H "Authorization: Bearer $TOKEN" \
	-H 'Accept: application/json' \
	-H 'Content-Type: application/json' \
	https://$ENDPOINT"${apipath}"
}

# GET an object, if one exists
function ocp_curl_get()
{
	apipath="$1"

	curl -k \
	-H "Authorization: Bearer $TOKEN" \
	-H 'Accept: application/json' \
	-H 'Content-Type: application/json' \
	https://$ENDPOINT"${apipath}"
}

# PATCH an object
function ocp_curl_patch()
{
	object="$1"
	apipath="$2"

	echo "${object}" |
	curl -k \
	-X PATCH \
	-d @- \
	-H "Authorization: Bearer $TOKEN" \
	-H 'Accept: application/json' \
	-H 'Content-Type: application/strategic-merge-patch+json' \
	https://$ENDPOINT"${apipath}"
}

# return the HTTP status from trying to get the resource
function ocp_curl_get_status()
{
	apipath="$1"

	curl -k \
	-s -o /dev/null -w "%{http_code}" \
	-H "Authorization: Bearer $TOKEN" \
	-H 'Accept: application/json' \
	-H 'Content-Type: application/json' \
	https://$ENDPOINT"${apipath}"
}

# if the project already exists, do not proceed
http_status=$(ocp_curl_get_status /apis/project.openshift.io/v1/projects/"${PROJECT_NAME}")
if [[ "${http_status}" == "403" ]]
then
	1>&2 echo "$0: received HTTP 403 getting project \"${PROJECT_NAME}\"; are you using a serviceaccount with sufficient roles bound to it?"
	exit 1
elif [[ "${http_status}" != "404" ]]
then
	1>&2 echo "$0: project \"${PROJECT_NAME}\" already exists; aborting"
	exit 1
fi

# create the project itself
obj=$(mktemp)
cat > ${obj} <<EOF
{
  "kind": "ProjectRequest",
  "apiVersion": "project.openshift.io/v1",
  "displayName": "${PROJECT_DISPLAY_NAME:-}",
  "metadata":
  {
    "name": "${PROJECT_NAME}"
  }
}
EOF
ocp_curl_put "$(cat ${obj})" /apis/project.openshift.io/v1/projectrequests
rm -f ${obj}

# apply an annotation to the project
# (ultimately, we want to record metadata in annotations--
# things like "which ServiceNow catalog entry was used to create this?"
# or "which team owns this project?".)
obj=$(mktemp)
cat > ${obj} <<"EOF"
{"metadata": {"annotations": {"dfs-servicenow-catalog-selection": "xxx-demo-catalog-selection"}}}
EOF
ocp_curl_patch "$(cat ${obj})" /api/v1/namespaces/${PROJECT_NAME}
rm -f ${obj}

# bind the "admin" and "edit" roles to the groups ${PROJECT_NAME}-admin
# and ${PROJECT_NAME}-edit, respectively.  Assume that these groups will
# be created at some point in the future.
obj=$(mktemp)
cat > ${obj} <<EOF
{
    "apiVersion": "authorization.openshift.io/v1",
    "groupNames": [
        "${PROJECT_NAME}-edit"
    ],
    "kind": "RoleBinding",
    "metadata": {
        "name": "${PROJECT_NAME}-edit",
        "namespace": "${PROJECT_NAME}"
    },
    "roleRef": {
        "name": "edit"
    },
    "subjects": [
        {
            "kind": "Group",
            "name": "${PROJECT_NAME}-edit"
        }
    ],
    "userNames": null
}
EOF
ocp_curl_put "$(cat ${obj})" /apis/authorization.openshift.io/v1/namespaces/${PROJECT_NAME}/rolebindings
rm -f ${obj}

obj=$(mktemp)
cat > ${obj} <<EOF
{
    "apiVersion": "authorization.openshift.io/v1",
    "groupNames": [
        "${PROJECT_NAME}-admin"
    ],
    "kind": "RoleBinding",
    "metadata": {
        "name": "${PROJECT_NAME}-admin",
        "namespace": "${PROJECT_NAME}"
    },
    "roleRef": {
        "name": "admin"
    },
    "subjects": [
        {
            "kind": "Group",
            "name": "${PROJECT_NAME}-admin"
        }
    ],
    "userNames": null
}
EOF
ocp_curl_put "$(cat ${obj})" /apis/authorization.openshift.io/v1/namespaces/${PROJECT_NAME}/rolebindings
rm -f ${obj}

# create the small limitrange inside the project
# ("medium" and "large" are cut for size, but it's the same concept)
obj=$(mktemp)
cat > ${obj} <<EOF
{
    "apiVersion": "v1",
    "kind": "LimitRange",
    "metadata": {
        "labels": {
            "quota-tier": "small"
        },
        "name": "limitrange-small",
        "namespace": "${PROJECT_NAME}"
    },
    "spec": {
        "limits": [
            {
                "default": {
                    "cpu": "200m",
                    "memory": "2Gi"
                },
                "defaultRequest": {
                    "cpu": "100m",
                    "memory": "512Mi"
                },
                "max": {
                    "cpu": "1",
                    "memory": "8Gi"
                },
                "maxLimitRequestRatio": {
                    "cpu": "20",
                    "memory": "512"
                },
                "min": {
                    "cpu": "50m",
                    "memory": "16Mi"
                },
                "type": "Container"
            }
        ]
    }
}
EOF
ocp_curl_put "$(cat ${obj})" /api/v1/namespaces/"${PROJECT_NAME}"/limitranges
rm -f ${obj}

# create the small quota inside the project
obj=$(mktemp)
cat > ${obj} <<EOF
{
    "apiVersion": "v1",
    "kind": "ResourceQuota",
    "metadata": {
        "labels": {
            "quota-tier": "small"
        },
        "name": "quota-small",
        "namespace": "${PROJECT_NAME}"
    },
    "spec": {
        "hard": {
            "limits.cpu": "10",
            "limits.memory": "64Gi",
            "pods": "150",
            "requests.cpu": "10",
            "requests.memory": "32Gi",
            "requests.storage": "50Gi"
        }
    },
    "status": {
        "hard": {
            "limits.cpu": "10",
            "limits.memory": "64Gi",
            "pods": "150",
            "requests.cpu": "10",
            "requests.memory": "32Gi",
            "requests.storage": "50Gi"
        },
        "used": {
            "limits.cpu": "0",
            "limits.memory": "0",
            "pods": "0",
            "requests.cpu": "0",
            "requests.memory": "0",
            "requests.storage": "0"
        }
    }
}
EOF
ocp_curl_put "$(cat ${obj})" /api/v1/namespaces/"${PROJECT_NAME}"/resourcequotas
rm -f ${obj}

