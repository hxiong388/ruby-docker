# Copyright 2016 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "minitest/autorun"
require_relative "../../test/test_helper"
require "fileutils"


class TestGenerateDockerfile < ::Minitest::Test
  include TestHelper

  TEST_DIR = ::File.dirname __FILE__
  BASE_DIR = ::File.dirname ::File.dirname TEST_DIR
  CASES_DIR = ::File.join TEST_DIR, "sample_apps"
  APPS_DIR = ::File.join BASE_DIR, "test/sample_apps"
  TMP_DIR = ::File.join TEST_DIR, "tmp"
  CONFIG_HEADER = "runtime: ruby\nenv: flex\n"

  def test_default_config
    run_generate_dockerfile "rack_app"
    assert_dockerfile_line "## Service: default"
    assert_dockerfile_commented "RUN apt-get update -y"
    assert_dockerfile_commented "RUN apt-get install -y -q"
    assert_dockerfile_commented "ARG REQUESTED_RUBY_VERSION="
    assert_dockerfile_commented "RUN apt-get clean"
    assert_dockerfile_commented "ENV NAME=\"value\""
    assert_dockerfile_line "RUN bundle install"
    assert_dockerfile_commented "ARG BUILD_CLOUDSQL_INSTANCES="
    assert_dockerfile_commented "RUN bundle exec rake assets:precompile"
    assert_dockerfile_line "CMD exec bundle exec rackup -p \\$PORT"
  end

  def test_config_path_and_service_name
    run_generate_dockerfile "rack_app", config_path: "myservice.yaml",
                            config: "service: myservicename"
    assert_dockerfile_line "## Service: myservicename"
  end

  def test_debian_packages
    config = <<~CONFIG
      runtime_config:
        packages:
          - libgeos-dev
          - libproj-dev
    CONFIG
    run_generate_dockerfile "rack_app", config: config
    assert_dockerfile_line "RUN apt-get update -y"
    assert_dockerfile_line "RUN apt-get install -y -q libgeos-dev libproj-dev"
    assert_dockerfile_line "RUN apt-get clean"
  end

  def test_ruby_version
    run_generate_dockerfile "rack_app", ruby_version: "2.4.1"
    assert_dockerfile_line "RUN apt-get update -y"
    assert_dockerfile_line "ARG REQUESTED_RUBY_VERSION=\"2\\.4\\.1\""
    assert_dockerfile_line "RUN apt-get clean"
  end

  def test_env_variables
    config = <<~CONFIG
      env_variables:
        VAR1: value1
        VAR2: "with space"
        VAR3: "\\"quoted\\"\\nnewline"
    CONFIG
    run_generate_dockerfile "rack_app", config: config
    assert_dockerfile_line "ENV VAR1=\"value1\""
    assert_dockerfile_line "ENV VAR2=\"with space\""
    assert_dockerfile_line "ENV VAR3=\"\\\\\"quoted\\\\\"\\\\nnewline\""
  end

  def test_sql_instances
    config = <<~CONFIG
      beta_settings:
        cloud_sql_instances:
          - my-proj:my-region:my-db
          - proj2:region2:db2
    CONFIG
    run_generate_dockerfile "rack_app", config: config
    assert_dockerfile_line "ARG BUILD_CLOUDSQL_INSTANCES=" \
        "\"my-proj:my-region:my-db,proj2:region2:db2\""
  end

  def test_custom_build_scripts
    config = <<~CONFIG
      lifecycle:
        build:
          - bundle exec rake do:something
          - bundle exec rake do:something:else
    CONFIG
    run_generate_dockerfile "rack_app", config: config
    assert_dockerfile_line "RUN bundle exec rake do:something"
    assert_dockerfile_line "RUN bundle exec rake do:something:else"
  end

  def test_custom_build_scripts_with_cloud_sql
    config = <<~CONFIG
      lifecycle:
        build:
          - bundle exec rake do:something
          - bundle exec rake do:something:else
      beta_settings:
        cloud_sql_instances: my-proj:my-region:my-db
    CONFIG
    run_generate_dockerfile "rack_app", config: config
    assert_dockerfile_line "RUN /build_tools/access_cloud_sql &&" \
        " bundle exec rake do:something"
    assert_dockerfile_line "RUN /build_tools/access_cloud_sql &&" \
        " bundle exec rake do:something:else"
  end

  def test_rails_default_build_scripts
    run_generate_dockerfile "rails5_app"
    assert_dockerfile_line "RUN bundle exec rake assets:precompile \\|\\| true"
  end

  def test_entrypoint
    config = <<~CONFIG
      entrypoint: bundle exec bin/rails s
    CONFIG
    run_generate_dockerfile "rack_app", config: config
    assert_dockerfile_line "CMD exec bundle exec bin/rails s"
  end

  def test_no_gemfile
    run_generate_dockerfile "rack_app", delete_gemfile: true
    assert_dockerfile_commented "RUN bundle install"
  end

  def test_env_variable_name_failure
    config = <<~CONFIG
      env_variables:
        hi-ho: value1
    CONFIG
    run_generate_dockerfile "rack_app", config: config, expect_failure: true
  end

  def test_debian_package_failure
    config = <<~CONFIG
      runtime_config:
        packages:
          - libgeos dev
    CONFIG
    run_generate_dockerfile "rack_app", config: config, expect_failure: true
  end

  def test_ruby_version_failure
    run_generate_dockerfile "rack_app",
                            ruby_version: "2.4.1\nRUN echo hi",
                            expect_failure: true
  end

  def test_sql_instances_failure
    config = <<~CONFIG
      beta_settings:
        cloud_sql_instances:
          - my-proj my-region:my-db
    CONFIG
    run_generate_dockerfile "rack_app", config: config, expect_failure: true
  end

  def test_build_scripts_failure
    config = <<~CONFIG
      lifecycle:
        build:
          - "bundle exec rake do:something\\nwith newline"
    CONFIG
    run_generate_dockerfile "rack_app", config: config, expect_failure: true
  end

  private

  def assert_dockerfile_line content
    assert_file_contents "#{TMP_DIR}/Dockerfile", %r{^#{content}}
  end

  def assert_dockerfile_commented content
    assert_file_contents "#{TMP_DIR}/Dockerfile", %r{^#\s#{content}}
  end

  def run_generate_dockerfile app_name,
                              config: "", config_path: "app.yaml",
                              ruby_version: "", delete_gemfile: false,
                              expect_failure: false
    app_dir = ::File.join APPS_DIR, app_name
    ::FileUtils.rm_rf TMP_DIR
    ::FileUtils.cp_r app_dir, TMP_DIR
    if config
      ::File.open ::File.join(TMP_DIR, config_path), "w" do |file|
        file.puts CONFIG_HEADER + config
      end
    end
    unless ruby_version.empty?
      ::File.open ::File.join(TMP_DIR, ".ruby-version"), "w" do |file|
        file.write ruby_version
      end
    end
    if delete_gemfile
      ::File.delete ::File.join(TMP_DIR, "Gemfile")
      ::File.delete ::File.join(TMP_DIR, "Gemfile.lock")
    end

    docker_args = "-v #{TMP_DIR}:/workspace -w /workspace" \
        " -e GAE_APPLICATION_YAML_PATH=#{config_path}" \
        " ruby-generate-dockerfile -t" \
        " --base-image=gcr.io/google-appengine/ruby:my-test-tag"
    if expect_failure
      assert_cmd_fails "docker run --rm #{docker_args}"
    else
      assert_docker_output docker_args, nil
      assert_file_contents "#{TMP_DIR}/Dockerfile",
          %r{FROM gcr\.io/google-appengine/ruby:my-test-tag AS augmented-base}
      assert_file_contents "#{TMP_DIR}/.dockerignore", /Dockerfile/
    end
  end
end
