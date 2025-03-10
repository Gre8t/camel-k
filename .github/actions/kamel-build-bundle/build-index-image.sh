#!/bin/bash

# ---------------------------------------------------------------------------
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------------

####
#
# Builds the kamel bundle index image
#
####

set -e

while getopts ":b:i:l:n:s:v:" opt; do
  case "${opt}" in
    b)
      BUNDLE_IMAGE=${OPTARG}
      ;;
    i)
      IMAGE_NAMESPACE=${OPTARG}
      ;;
    l)
      REGISTRY_PULL_HOST=${OPTARG}
      ;;
    n)
      IMAGE_NAME=${OPTARG}
      ;;
    s)
      REGISTRY_PUSH_HOST=${OPTARG}
      ;;
    v)
      IMAGE_VERSION=${OPTARG}
      ;;
    :)
      echo "ERROR: Option -$OPTARG requires an argument"
      exit 1
      ;;
    \?)
      echo "ERROR: Invalid option -$OPTARG"
      exit 1
      ;;
  esac
done
shift $((OPTIND-1))

if [ -z "${BUNDLE_IMAGE}" ]; then
  echo "Error: build-bundle-local-image not defined"
  exit 1
fi

if [ -z "${IMAGE_NAME}" ]; then
  echo "Error: local-image-name not defined"
  exit 1
fi

if [ -z "${IMAGE_VERSION}" ]; then
  echo "Error: local-image-version not defined"
  exit 1
fi

if [ -z "${IMAGE_NAMESPACE}" ]; then
  echo "Error: image-namespace not defined"
  exit 1
fi

if [ -z "${REGISTRY_PUSH_HOST}" ]; then
  echo "Error: image-registry-push-host not defined"
  exit 1
fi

if [ -z "${REGISTRY_PULL_HOST}" ]; then
  echo "Error: image-registry-pull-host not defined"
  exit 1
fi

export LOCAL_IIB=${REGISTRY_PUSH_HOST}/${IMAGE_NAMESPACE}/camel-k-iib:${IMAGE_VERSION}
if ! command -v opm &> /dev/null
then
  echo "opm could not be found. Has it not been installed?"
  exit 1
fi

# Shorten the vars
PUSH_REGISTRY=${REGISTRY_PUSH_HOST}
PULL_REGISTRY=${REGISTRY_PULL_HOST}

#
# opm requires an active pull registry from which to verify (if not download) the bundle image
# Since the image-registry-pull-host may not be visible (eg. in the case of openshift), we need
# to fake the registry to allow opm to complete its task of creating an index image.
#
# 1. Add and alias to the hosts file for the name of the image-registry
# 2. Run a container of registry:2 docker image on the same port as the image-registry (port 80 if not present)
# 3. Tag and them push the image to the registry using docker
# 4. Run opm
#

if [ "${PULL_REGISTRY}" != "${PUSH_REGISTRY}" ]; then
  #
  # With the registry interfaces different then good chance that
  # pull registry is not externally accessible, eg. openshift
  #

  PULL_HOST=$(echo ${PULL_REGISTRY} | sed -e 's/\(.*\):.*/\1/')
  PULL_PORT=$(echo ${PULL_REGISTRY} | sed -e 's/.*:\([0-9]\+\).*/\1/')
  if [ -z "${PULL_PORT}" ]; then
    # Use standard http port
    PULL_PORT=80
  fi

  echo "Impersonating registry at ${PULL_HOST}:${PULL_PORT}"

  #
  # Update both ipv4 and ipv6 addresses if they exist
  # 127.0.0.1 localhost
  # ::1     localhost ip6-localhost ip6-loopback
  sudo sed -i "s/\(localhost.*\)/\1 ${PULL_HOST}/g" /etc/hosts

  #
  # Bring up the registry:2 instance if not already started
  #
  reg=$(docker ps -a -q -f name=triage-registry)
  if [ -n "${reg}" ]; then
    docker stop triage-registry
    docker rm triage-registry
  fi

  docker run -d -p ${PULL_PORT}:5000 --name triage-registry registry:2

  #
  # Tag the bundle image
  #
  docker tag \
    ${PUSH_REGISTRY}/${IMAGE_NAMESPACE}/camel-k-bundle:${IMAGE_VERSION} \
    ${BUNDLE_IMAGE}

  # Push the bundle image to the registry
  #
  docker push ${BUNDLE_IMAGE}
fi

#
# Construct an index image containing the newly built bundle image
#   Bug:
#     https://github.com/operator-framework/operator-registry/issues/870
#   Workaround:
#     image catalog layers contain root owned files so fails with `permission denied` error.
#     Running with sudo fixes this error (alternative is to switch to podman)
#
sudo opm index add \
  -c docker --skip-tls \
  --bundles ${BUNDLE_IMAGE} \
  --from-index quay.io/operatorhubio/catalog:latest \
  --tag ${LOCAL_IIB}

docker push ${LOCAL_IIB}
BUILD_BUNDLE_LOCAL_IMAGE_BUNDLE_INDEX="${REGISTRY_PULL_HOST}/${IMAGE_NAMESPACE}/camel-k-iib:${IMAGE_VERSION}"
echo "Setting build-bundle-image-bundle-index to ${BUILD_BUNDLE_LOCAL_IMAGE_BUNDLE_INDEX}"
echo "::set-output name=build-bundle-image-bundle-index::${BUILD_BUNDLE_LOCAL_IMAGE_BUNDLE_INDEX}"
