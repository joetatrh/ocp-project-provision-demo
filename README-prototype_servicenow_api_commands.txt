Prototyping new-project provisioning on OCP
2018-11-15

SYNOPSIS:
---------

We plan to use ServiceNow to onboard new projects into OpenShift.  ServiceNow will hit the OpenShift API to create the objects associated with the new project.

REFERENCES:
-----------

- https://docs.openshift.com/container-platform/3.11/rest_api/index.html#rest-api-serviceaccount-tokens
- https://docs.openshift.com/container-platform/3.7/rest_api/apis-project.openshift.io/v1.ProjectRequest.html

PREREQUISITES:
--------------

For the purposes of this demo, a user with "cluster-admin" privileges must be logged into the "oc" command line.

PREFLIGHT CLEANUP:
------------------

If you have previously performed this demo, ensure that you have deleted all the objects associated with it:

# ignore any errors, as some may not exist
oc delete project foo-project
oc -n default adm policy remove-cluster-role-from-user custom-project-provisioner -z custom-project-provisioner
oc delete clusterrole custom-project-provisioner
oc -n default delete serviceaccount custom-project-provisioner

ONE-TIME INITIALIZATION:
------------------------

First, disable the ability for users to create (provision) their own projects:

oc adm policy remove-cluster-role-from-group self-provisioner system:authenticated:oauth
oc adm policy remove-cluster-role-from-group self-provisioner system:authenticated

Next, we'll need a token to access the OpenShift API.

On a one-time basis, we create a new serviceaccount just for new-project provisioning.  Later, we'll tell ServiceNow to send a token associated with this serviceaccount along with its requests.

# create the serviceaccount
oc -n default create serviceaccount custom-project-provisioner

# grant the serviceaccount the "cluster-admin" role
# (which may offer more permissions than we really need)
oc -n default adm policy add-cluster-role-to-user cluster-admin -z custom-project-provisioner

---> FUTURE WORK: TIGHTER PERMISSIONS ON SERVICEACCOUNT

It's likely overkill to grant the "cluster-admin" role to the serviceaccount.

Additional work is necessary to fine-tune these permissions.  (For example, you might find that the only OCP permissions necessary are to "CREATE" on objects of type ProjectRequest, LimitRange, & ResourceQuota.)

Once the set of permissions have been identified, refine permissions like so:

# remove the "cluster-admin" rolebinding from the serviceaccount
oc -n default adm policy remove-cluster-role-from-user cluster-admin custom-project-provisioner
oc delete clusterrole custom-project-provisioner

# dump a copy of the cluster-admin clusterrole, renaming it at the same time
oc get clusterrole cluster-admin -o yaml | sed -e 's/cluster-admin/custom-project-provisioner/g' > clusterrole_custom-project-provisioner.yaml

# edit the clusterrole to reduce its permissions
vim clusterrole_custom-project-provisioner.yaml

# EXAMPLE: the following clusterrole can get and create projects,
# create limitranges and resourcequotas, and do nothing else:
##---
##apiVersion: authorization.openshift.io/v1
##kind: ClusterRole
##metadata:
##  name: custom-project-provisioner
##rules:
##- apiGroups:
##  - 'project.openshift.io'
##  attributeRestrictions: null
##  resources:
##  - 'projectrequests'
##  verbs:
##  - 'get'
##  - 'create'
##- apiGroups: null
##  attributeRestrictions: null
##  nonResourceURLs:
##  - '*'
##  resources:
##  - 'limitranges'
##  - 'resourcequotas'
##  verbs:
##  - 'create'

# create the new clusterrole and bind it to the servicaccount
oc create -f clusterrole_custom-project-provisioner.yaml
oc -n default adm policy add-cluster-role-to-user custom-project-provisioner -z custom-project-provisioner

# now run the script ./prototype-onboard_new_project.sh .
# it has sufficient privileges to do its job

