#!/rbenv/shims/ruby

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

require "json"
require_relative "build_info.rb"

class BuildScript
  def initialize args
    @build = BuildInfo.new args
    @build.banner "ruby-build-app", <<~DESCRIPTION
      Runs Rails asset precompilation, and/or other application-defined
      build scripts.
    DESCRIPTION
  end

  def main
    unless @build.build_scripts.empty?
      install_binaries
      install_bundle
      setup_env_variables
      start_services
      run_build_scripts
      stop_services
      @build.cleanup_file_perms
    end
  end

  def install_binaries
    ruby_version = @build.ruby_version
    packages = @build.install_packages
    rbenv_dir = @build.rbenv_dir
    if !ruby_version.empty? || !packages.empty?
      @build.log "Initializing apt-get in build container..."
      @build.ensure_cmd "apt-get update -y"
      if !packages.empty?
        @build.log "Installing additional packages into build container..."
        @build.ensure_cmd "apt-get install -y -q #{packages.join(' ')}"
      end
      unless ruby_version.empty?
        unless ::File.executable? \
            "#{rbenv_dir}/versions/#{ruby_version}/bin/ruby"
          @build.log "Installing Ruby #{ruby_version} into build container..."
          unless @build.check_cmd \
              "apt-get install -y -q gcp-ruby-#{ruby_version}"
            ::Dir.chdir "#{rbenv_dir}/plugins/ruby-build" do
              @build.log "Need to build Ruby #{ruby_version} from source..."
              @build.ensure_cmd "git pull"
              @build.ensure_cmd "rbenv install -s #{ruby_version}"
            end
          end
        end
        ENV.delete "RBENV_VERSION"
        ENV["PATH"] = "#{rbenv_dir}/shims:#{ENV['PATH']}"
        @build.ensure_cmd "rbenv global #{ruby_version}"
        @build.log "Installing bundler..."
        @build.ensure_cmd "gem install -q --no-rdoc --no-ri bundler" \
            " --version #{::ENV['BUNDLER_VERSION']}"
      end
    end
  end

  def install_bundle
    if ::File.file?("Gemfile.lock")
      @build.log "Installing bundled gems..."
      @build.ensure_cmd \
          "bundle install --deployment --without='development test'"
      @build.ensure_cmd "rbenv rehash"
    end
  end

  def setup_env_variables
    @build.env_variables.each do |k, v|
      ENV[k.to_s] = v.to_s
    end
  end

  def start_services
    @cloudsql_proxy_pid = nil
    sql_instances = @build.cloud_sql_instances.join(',')
    return if sql_instances.empty?
    proxy_ok = false
    begin
      auth_token = get_auth_token
      @build.log "Starting CloudSQL Proxy..."
      @build.log "Connecting to #{sql_instances}"
      cmd = "#{@build.builder_dir}/cloud_sql_proxy -dir=/cloudsql " +
        "-token='#{auth_token}' -instances=#{sql_instances}"
      io = ::IO.popen cmd, "r", err: [:child, :out]
      @cloudsql_proxy_pid = io.pid
      io.each_line do |line|
        @build.log line
        if line =~ /Ready for new connections/
          proxy_ok = true
          @build.log "CloudSQL Proxy is ready."
          break
        end
      end
    rescue => e
      @build.log e.inspect
    end
    @build.log "Failed to start CloudSQL Proxy" unless proxy_ok
  end

  def stop_services
    if @cloudsql_proxy_pid
      @build.log "Shutting down CloudSQL Proxy"
      ::Process.kill "KILL", @cloudsql_proxy_pid
    end
  end

  def run_build_scripts
    @build.build_scripts.each do |script|
      @build.log "Running build script: #{script}"
      @build.ensure_cmd script
    end
  end

  def get_auth_token
    cmd = 'curl -H "Metadata-Flavor: Google" http://metadata.google.internal/' +
      'computeMetadata/v1/instance/service-accounts/default/token'
    json = `#{cmd}`
    raise "Unable to get auth token" unless json.start_with? '{"'
    token_data = JSON.parse json
    @build.log "Access token expires in #{token_data["expires_in"]} ms."
    token_data["access_token"]
  end
end

BuildScript.new(::ARGV).main
