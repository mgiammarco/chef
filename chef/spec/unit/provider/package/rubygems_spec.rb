#
# Author:: David Balatero (dbalatero@gmail.com)
#
# Copyright:: Copyright (c) 2009 David Balatero 
# License:: Apache License, Version 2.0
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
#

require File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "spec_helper"))

describe Chef::Provider::Package::Rubygems, "gem_binary_path" do
  before(:each) do
    @node = mock("Chef::Node", :null_object => true)
    @new_resource = mock("Chef::Resource::Package",
      :null_object => true,
      :name => "rspec",
      :version => "1.2.2",
      :package_name => "rspec",
      :updated => nil,
      :gem_binary => nil
    )
    @provider = Chef::Provider::Package::Rubygems.new(@node, @new_resource)
  end

  it "should return a relative path to gem if no gem_binary is given" do
    @provider.gem_binary_path.should eql("gem")
  end

  it "should return a specific path to gem if a gem_binary is given" do
    @new_resource.should_receive(:gem_binary).and_return("/opt/local/bin/custom/ruby")
    @provider.gem_binary_path.should eql("/opt/local/bin/custom/ruby")
  end
end

describe Chef::Provider::Package::Rubygems, "install_package" do
  before(:each) do
    @node = mock("Chef::Node", :null_object => true)
    @new_resource = Chef::Resource::GemPackage.new("rspec")
    @new_resource.version "1.2.2"
    @provider = Chef::Provider::Package::Rubygems.new(@node, @new_resource)
  end

  it "should run gem install with the package name and version" do
    @provider.should_receive(:run_command).with({
      :command => "gem install rspec -q --no-rdoc --no-ri -v \"1.2.2\"",
      :environment => {
        "LC_ALL" => nil
      }
    })
    @provider.install_package("rspec", "1.2.2")
  end
  
  it "installs gems with arbitrary options set by resource's options" do
    @new_resource.options "-i /arbitrary/install/dir"
    @provider.should_receive(:run_command_with_systems_locale).
      with(:command => "gem install rspec -q --no-rdoc --no-ri -v \"1.2.2\" -i /arbitrary/install/dir")
    @provider.install_package("rspec", "1.2.2")
  end
end
