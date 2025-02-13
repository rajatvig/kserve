/*
Copyright 2021 The KServe Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package v1beta1

import (
	"strconv"

	"github.com/kserve/kserve/pkg/constants"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// SKLearnSpec defines arguments for configuring SKLearn model serving.
type SKLearnSpec struct {
	// Contains fields shared across all predictors
	PredictorExtensionSpec `json:",inline"`
}

var (
	_ ComponentImplementation = &SKLearnSpec{}
)

// Default sets defaults on the resource
func (k *SKLearnSpec) Default(config *InferenceServicesConfig) {
	k.Container.Name = constants.InferenceServiceContainerName

	if k.ProtocolVersion == nil {
		defaultProtocol := constants.ProtocolV1
		k.ProtocolVersion = &defaultProtocol
	}

	setResourceRequirementDefaults(config, &k.Resources)
}

// nolint: unused
func (k *SKLearnSpec) getEnvVarsV2() []v1.EnvVar {
	vars := []v1.EnvVar{
		{
			Name:  constants.MLServerHTTPPortEnv,
			Value: strconv.Itoa(int(constants.MLServerISRestPort)),
		},
		{
			Name:  constants.MLServerGRPCPortEnv,
			Value: strconv.Itoa(int(constants.MLServerISGRPCPort)),
		},
		{
			Name:  constants.MLServerModelsDirEnv,
			Value: constants.DefaultModelLocalMountPath,
		},
	}

	if k.StorageURI == nil {
		vars = append(
			vars,
			v1.EnvVar{
				Name:  constants.MLServerLoadModelsStartupEnv,
				Value: strconv.FormatBool(false),
			},
		)
	}

	return vars
}

// nolint: unused
func (k *SKLearnSpec) getDefaultsV2(metadata metav1.ObjectMeta) []v1.EnvVar {
	// These env vars set default parameters that can always be overridden
	// individually through `model-settings.json` config files.
	// These will be used as fallbacks for any missing properties and / or to run
	// without a `model-settings.json` file in place.
	vars := []v1.EnvVar{
		{
			Name:  constants.MLServerModelImplementationEnv,
			Value: constants.MLServerSKLearnImplementation,
		},
	}

	if k.StorageURI != nil {
		// These env vars only make sense as a default for non-MMS servers
		vars = append(
			vars,
			v1.EnvVar{
				Name:  constants.MLServerModelNameEnv,
				Value: metadata.Name,
			},
			v1.EnvVar{
				Name:  constants.MLServerModelURIEnv,
				Value: constants.DefaultModelLocalMountPath,
			},
		)
	}

	return vars
}

func (k *SKLearnSpec) GetContainer(metadata metav1.ObjectMeta, extensions *ComponentExtensionSpec, config *InferenceServicesConfig, predictorHost ...string) *v1.Container {
	return &k.Container
}

func (k *SKLearnSpec) GetProtocol() constants.InferenceServiceProtocol {
	if k.ProtocolVersion != nil {
		return *k.ProtocolVersion
	} else {
		return constants.ProtocolV1
	}
}
