# Copyright 2021 The KServe Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# coding: utf-8

"""
    KServe

    Python SDK for KServe  # noqa: E501

    The version of the OpenAPI document: v0.1
    Generated by: https://openapi-generator.tech
"""


from __future__ import absolute_import

import unittest
import datetime

import kserve
from kserve.models.v1beta1_custom_explainer import V1beta1CustomExplainer  # noqa: E501
from kserve.rest import ApiException

class TestV1beta1CustomExplainer(unittest.TestCase):
    """V1beta1CustomExplainer unit test stubs"""

    def setUp(self):
        pass

    def tearDown(self):
        pass

    def make_instance(self, include_optional):
        """Test V1beta1CustomExplainer
            include_option is a boolean, when False only required
            params are included, when True both required and
            optional params are included """
        # model = kserve.models.v1beta1_custom_explainer.V1beta1CustomExplainer()  # noqa: E501
        if include_optional :
            return V1beta1CustomExplainer(
                active_deadline_seconds = 56, 
                affinity = None, 
                automount_service_account_token = True, 
                containers = [
                    None
                    ], 
                dns_config = None, 
                dns_policy = '0', 
                enable_service_links = True, 
                ephemeral_containers = [
                    None
                    ], 
                host_aliases = [
                    None
                    ], 
                host_ipc = True, 
                host_network = True, 
                host_pid = True, 
                hostname = '0', 
                image_pull_secrets = [
                    None
                    ], 
                init_containers = [
                    None
                    ], 
                node_name = '0', 
                node_selector = {
                    'key' : '0'
                    }, 
                overhead = {
                    'key' : None
                    }, 
                preemption_policy = '0', 
                priority = 56, 
                priority_class_name = '0', 
                readiness_gates = [
                    None
                    ], 
                restart_policy = '0', 
                runtime_class_name = '0', 
                scheduler_name = '0', 
                security_context = None, 
                service_account = '0', 
                service_account_name = '0', 
                share_process_namespace = True, 
                subdomain = '0', 
                termination_grace_period_seconds = 56, 
                tolerations = [
                    None
                    ], 
                topology_spread_constraints = [
                    None
                    ], 
                volumes = [
                    None
                    ]
            )
        else :
            return V1beta1CustomExplainer(
                containers = [
                    None
                    ],
        )

    def testV1beta1CustomExplainer(self):
        """Test V1beta1CustomExplainer"""
        inst_req_only = self.make_instance(include_optional=False)
        inst_req_and_optional = self.make_instance(include_optional=True)


if __name__ == '__main__':
    unittest.main()