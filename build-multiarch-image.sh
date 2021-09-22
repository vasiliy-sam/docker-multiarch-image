#!/usr/bin/env bash
set -e
#set -x
set -o pipefail

#create ssh arent instance and add ssh key inside
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa_github;

###
#
#  Physical machines necessary to build images per arch using native arch architecture
#  Images built using QEMU-emulator might be very slow or they even could not work at all (for example throw 'Segmentation fault' errors)
#  We use docker buildx feature here. At the moment (Sep 2021) it does not provide the possibility to build all remote parts using one command.
#  Build context also does not seem to work due to docker server connection errors. So building through SSH looks the best option now.
#  The main idea of multi-arch building here includes the following steps:
#    - build and push to docker-hub all required images on physical machines with corresponding architecture
#    - create and push combined docker manifest with unions all repo images
#    - delete not needed separate arch tags from the docker hub
#  As a result one multi arch image left in registry
#  And client OS will choose the appropriate digest to pull based on the required architecture existing in the image manifest (one tag)
#
###
#
#  Arch host server pre-prerequisites:
#    - Non-interactive SSH connection, SSH key is the preferrable way.
#    - installed latest docker (docker > 20.0 ; API > 1.41.0)
#      > curl -fsSL test.docker.com -o get-docker.sh && sh get-docker.sh
#      > sudo usermod -aG docker $USER
#    - docker binaries must be added to env PATH. (workingfrom scratch on AWS)
#      if bins not exposed (for example on physical Mac M1):
#        export PATH="......" > ~/.ssh/environment
#        PermitUserEnvironment yes -> /etc/ssh/sshd_config
#
#  To receive the DOCKER_TOKEN you can just perform docker login locally and then copy the generated auth key from the file ~/.docker/config.json
#
###

### Usage:
#  > _php_version=7.4
#  > IMAGE_NAME="vasiliysam/nginx-php${_php_version}" \
#    IMAGE_TAG="multiarch-latest" \
#    REPO_URL="ssh://git@mygitstorage.com/doc/image1.git" \
#    REPO_BRANCH="multiarch" \
#    BUILD_ARGS_LINE="--build-arg PHP_VERSION_ARG=${_php_version} --build-arg FROM_TAG_ARG=multiarch-latest" \
#    DOCKER_TOKEN="123mytoken" \
#    DOCKER_LOGIN="myhublogin" \
#    DOCKER_PASS="myhubpass123" \
#    BASE_MANIFEST_CONNECTION='ssh -A username1@123.123.1.12' \
#    ARCH_CONNECTIONS_MAPPING='linux/amd64::ssh -A username1@123.123.1.12; linux/arm64/v8::ssh -A username2@123.123.1.23' \
#    USE_CACHE='0' \
#    bash ./build-multiarch-image.sh
###


##################### Incoming Args #######################

# image name and tag to build
IMAGE_NAME=${IMAGE_NAME-""}
IMAGE_TAG=${IMAGE_TAG-"$(date +'%Y%m%d%H%M%S')"}

# additional build arguments, format "--build-arg PARAM1=VALUE1 --build-arg PARAM2=VALUE2"
BUILD_ARGS_LINE=${BUILD_ARGS_LINE-''}

# repo url and branch with Dockerfile and configs
REPO_URL=${REPO_URL-''}
REPO_BRANCH=${REPO_BRANCH-'master'}

# [optional] for logged in build pushing, also login+pass could be used instead if token not given
DOCKER_TOKEN=${DOCKER_TOKEN-''}
# for image removal and/or docker login
DOCKER_LOGIN=${DOCKER_LOGIN-''}
DOCKER_PASS=${DOCKER_PASS-''}

# host to generate docker manifest, could be any host with installed docker, expected format: "ssh -A username1@123.123.1.12"
BASE_MANIFEST_CONNECTION=${BASE_MANIFEST_CONNECTION-''}
# hosts to generate docker images, format: "linux/amd64::ssh -A username1@123.123.1.12; linux/arm64/v8::ssh -A username2@123.123.1.23"
ARCH_CONNECTIONS_MAPPING=${ARCH_CONNECTIONS_MAPPING-''}


# directory to clone repo with build Dockerfile and configs
WORKING_DIR=${WORKING_DIR-"/tmp/docker_image/build_"$(date +'%F_%T')}

USE_CACHE=${USE_CACHE-'1'}

##################### Incoming Args END #######################


##################### Internal vars and checks #######################

if [ -z "${BASE_MANIFEST_CONNECTION}" ] || [ -z "${ARCH_CONNECTIONS_MAPPING}" ]; then
  echo "Build hosts connection can not be empty. Both vars BASE_MANIFEST_CONNECTION and ARCH_CONNECTIONS_MAPPING must be specified"
fi
IFS=";" read -r -a  ARCH_CONNECTIONS_MAPPING_ARR <<< "$ARCH_CONNECTIONS_MAPPING"

if [ -z "${DOCKER_LOGIN}" ] || [ -z "${DOCKER_PASS}" ]; then
  echo "Docker credentials are not specified. Both env vars DOCKER_LOGIN and DOCKER_PASS must be defined"
fi

if [ -z "${REPO_URL}" ] || [ -z "${REPO_BRANCH}" ]; then
  echo "Dockerfile repository and branch cannot be empty. Both vars REPO_URL or REPO_BRANCH must be specified"
fi

working_image_dir="${WORKING_DIR}/$(echo ${IMAGE_NAME} | tr -s '/ ' '_')"

if [ ! -z "${DOCKER_TOKEN}" ]; then
  # login command fails on Mac on M1 machine due to credsHelper interaction, so we can just put the predefined token, the same action performs 'docker login' command
  docker_login_cmd="mkdir -p ~/.docker && echo '{ \"auths\": { \"https://index.docker.io/v1/\": { \"auth\": \"${DOCKER_TOKEN}\" } } }' > ~/.docker/config.json"
else
  docker_login_cmd="echo '${DOCKER_PASS}' | docker login --username '${DOCKER_LOGIN}' --password-stdin"
fi

##################### Internal vars and checks END #######################

##################### Helper Functions #######################

run_cmd_on_all_build_hosts() {
  _command=${1-''}

  if [ -z "${_command}" ]; then
    echo "Remote command cannot be empty"
    exit 1
  fi

  local _current_connection_cmd
  for _arch_mapping in "${ARCH_CONNECTIONS_MAPPING_ARR[@]}"; do
    _current_connection_cmd="$(echo "${_arch_mapping}" | awk -F'::' '{print $2}')"

    # Prevent local var/function substitution using "\${_command}" to expand last variables on remote machine
    # All required local vars should be substituted before calling
    eval "${_current_connection_cmd} \${_command}"
  done
}

run_cmd_on_arch_host() {
  _arch=${1-''}
  _command=${2-''}

  if [ -z "${_command}" ]; then
    echo "Remote command cannot be empty"
    exit 1
  fi

  local _current_arch
  local _current_connection_cmd
  for _arch_mapping in "${ARCH_CONNECTIONS_MAPPING_ARR[@]}"; do
    _current_arch="$(echo "${_arch_mapping}" | awk -F'::' '{print $1}')"
    _current_connection_cmd="$(echo "${_arch_mapping}" | awk -F'::' '{print $2}')"

    if [[ "${_current_arch}" == "${_arch}" ]]; then
      # Prevent local var/function substitution using "\${_command}" to expand last variables on remote machine
      # All required local vars should be substituted before calling
      eval "${_current_connection_cmd} \${_command}"
    fi
  done
}

run_on_manifest_host(){
  _command=${1-''}

  # Prevent var/function substitution using "\${_command}" by calling on remote machine
  # required local vars should be substituted before calling
  eval "${BASE_MANIFEST_CONNECTION} \${_command}"
}

##################### Helper Functions END #######################


##################### Main body #######################

echo "######################################################################################################"
echo "#        Building the image ${IMAGE_NAME}:${IMAGE_TAG}"
echo "######################################################################################################"

image_arch_tags=()

tmp_pid_dir=$(mktemp -d -t docker_build-XXXXXXXXXX)
build_pids=()

for _arch_mapping in "${ARCH_CONNECTIONS_MAPPING_ARR[@]}"; do
  _arch="$(echo "${_arch_mapping}" | awk -F'::' '{print $1}')"
  _connection_cmd="$(echo "${_arch_mapping}" | awk -F'::' '{print $2}')"

  # get image tag temporary suffix, "linux/arm64/v8" -> "arm64v8"
  tag_arch_suffix=$(echo "${_arch}" | sed 's/linux//' | tr -d ' /')
  image_arch_tag="${IMAGE_TAG}-${tag_arch_suffix}"
  echo "############# Starting background building of the arch ${_arch} using remote connection ${_connection_cmd} #############"

  run_cmd_on_arch_host "${_arch}" "if [[ -d '${WORKING_DIR}' ]]; then rm -rf '${WORKING_DIR}'; fi && mkdir -p '${WORKING_DIR}'"
  run_cmd_on_arch_host "${_arch}" "mkdir -p ${working_image_dir}"
  run_cmd_on_arch_host "${_arch}" "git clone --branch ${REPO_BRANCH} --recursive --quiet --dissociate ${REPO_URL} ${working_image_dir}"
  run_cmd_on_arch_host "${_arch}" "${docker_login_cmd}"

  if [[ "${USE_CACHE}" == "1" ]]; then
    # these 2 commands needed only for build caching feature (--cache-from, --cache-to build options)
    # common cache across the build instances using docker registry can speedup builds, but some pushing output will be cut
    run_cmd_on_arch_host "${_arch}" "if [[ -z \$(docker buildx ls | grep 'docker-multiarch' ) ]]; then docker buildx create --name docker-multiarch --driver docker-container --use; fi"
    # start bootsrtap if not running yet
    run_cmd_on_arch_host "${_arch}" "docker buildx inspect --bootstrap"

    build_command="docker buildx build \
                     --pull \
                     --progress=plain \
                     ${BUILD_ARGS_LINE} \
                     --platform=${_arch} \
                     --cache-from=type=registry,ref='docker.io/${IMAGE_NAME}:cache' \
                     --cache-from=type=registry,ref='docker.io/${IMAGE_NAME}:latest' \
                     --cache-from=type=registry,ref='docker.io/${IMAGE_NAME}:${IMAGE_TAG}' \
                     --cache-from=type=registry,ref='docker.io/${IMAGE_NAME}:${image_arch_tag}' \
                     --cache-to=type=registry,ref='docker.io/${IMAGE_NAME}:cache',mode=max \
                     --tag ${IMAGE_NAME}:${image_arch_tag} \
                     --push \
                     ${working_image_dir}"
  else
    run_cmd_on_arch_host "${_arch}" "if [[ ! -z \$(docker buildx ls | grep 'docker-multiarch' ) ]]; then docker buildx rm docker-multiarch; fi"
    build_command="docker buildx build \
                     --pull \
                     --progress=plain \
                     ${BUILD_ARGS_LINE} \
                     --platform=${_arch} \
                     --no-cache \
                     --tag ${IMAGE_NAME}:${image_arch_tag} \
                     --push \
                     ${working_image_dir}"
  fi
  # run commands on remote host as a background process and write exit code to the local tmp file
  (set +e; eval "${_connection_cmd} ${build_command}"; echo "$?" > "${tmp_pid_dir}/${tag_arch_suffix}"; set -e) &
  build_pids+=("$!")

  image_arch_tags+=("${image_arch_tag}")
done

echo "############# Waiting for completion of all arch builds on remote hosts #############"
for _build_pid in "${build_pids[@]}"; do
  wait "${_build_pid}"
done

for _build_pid_file in "${tmp_pid_dir}"/*; do
  if [ "$(cat "${_build_pid_file}")" != "0" ]; then
    echo "Fatal error. Build on remote host '$(basename "${_build_pid_file}")' finished with non-zero exit code. See the output above.";
    echo "Created images will be removed.";
    run_cmd_on_all_build_hosts "if [[ ! -z \$(docker image ls '${IMAGE_NAME}:${IMAGE_TAG}*' --quiet) ]]; then docker rmi --force \$(docker image ls '${IMAGE_NAME}:${IMAGE_TAG}*' --quiet); fi"
    exit 1
  fi
done

echo "############# Building of all arches DONE #############"

echo "############# Creating combined manifest: ${IMAGE_NAME}:${IMAGE_TAG} #############"
manifest_create_cmd="docker manifest create '${IMAGE_NAME}:${IMAGE_TAG}'"
for _image_arch_tag in "${image_arch_tags[@]}"; do
  manifest_create_cmd="${manifest_create_cmd} --amend ${IMAGE_NAME}:${_image_arch_tag}"
done

run_on_manifest_host "${docker_login_cmd}"
run_on_manifest_host "${manifest_create_cmd}"
run_on_manifest_host "docker manifest push --purge ${IMAGE_NAME}:${IMAGE_TAG}"


echo "############# Removal of separate image tags on the docker hub keeping combined the manifest #############"
api_jwt_token=$(curl -s -H "Content-Type: application/json" -X POST -d "{\"username\":\"${DOCKER_LOGIN}\", \"password\":\"${DOCKER_PASS}\"}" "https://hub.docker.com/v2/users/login/" | jq -r .token)
for _image_arch_tag in "${image_arch_tags[@]}"; do
    # curl returns 0 exit code even by failed request, so added curl option --fail
    curl -L --fail "https://hub.docker.com/v2/repositories/${IMAGE_NAME}/tags/${_image_arch_tag}/" \
      -X DELETE \
      -H "Authorization: JWT ${api_jwt_token}"
    # curl errors are not caught by set -e, added option --fail return response code, but we lose the response
    if [ "$?" != "0" ]; then
      echo "Unable to delete remote arch tags."
      exit 1
    fi
done

echo "############# Cleanup the temporary data on all hosts #############"
run_cmd_on_all_build_hosts "docker builder prune --force"
run_cmd_on_all_build_hosts "if [[ ! -z \$(docker image ls '${IMAGE_NAME}:${IMAGE_TAG}*' --quiet) ]]; then docker rmi --force \$(docker image ls '${IMAGE_NAME}:${IMAGE_TAG}*' --quiet); fi"
run_cmd_on_all_build_hosts "rm -rf ${WORKING_DIR}"
if [[ -d "${tmp_pid_dir}" ]]; then rm -rf "${tmp_pid_dir}"; fi

echo "######################################################################################################"
echo "#                          All builds have been successfully finished                                #"
echo "######################################################################################################"
