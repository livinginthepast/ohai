#
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Claire McQuin (<claire@opscode.com>)
# Copyright:: Copyright (c) 2008, 2013 Opscode, Inc.
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

require File.expand_path(File.dirname(__FILE__) + '/../spec_helper.rb')
tmp = ENV['TMPDIR'] || ENV['TMP'] || ENV['TEMP'] || '/tmp'

describe "Ohai::System" do
  before(:all) do
    @plugin_path = Ohai::Config[:plugin_path]

    begin
      Dir.mkdir("#{tmp}/plugins")
    rescue Errno::EEXIST
      # ignore
    end
  end

  before(:each) do
    @ohai = Ohai::System.new
  end

  after(:all) do
    Ohai::Config[:plugin_path] = @plugin_path

    begin
      Dir.delete("#{tmp}/plugins")
    rescue
      # ignore
    end
  end

  describe "#initialize" do
    it "should return an Ohai::System object" do
      @ohai.should be_a_kind_of(Ohai::System)
    end

    it "should set @attributes to a Mash" do
      @ohai.attributes.should be_a_kind_of(Mash)
    end

    it "should set @v6_dependency_solver to a Hash" do
      @ohai.v6_dependency_solver.should be_a_kind_of(Hash)
    end
  end

  describe "#load_plugins" do
    before(:all) do
      Dir.should_receive(:[]).with("#{tmp}/plugins/*")
      Dir.should_receive(:[]).with("#{tmp}/plugins/#{Ohai::OS.collect_os}/**/*").and_return([])
    end

    before(:each) do
      f = File.open("#{tmp}/plugins/plgn.rb", "w+")
      f.write("Ohai.plugin do\nend\n")
      f.close
    end

    after(:each) do
      File.delete("#{tmp}/plugins/plgn.rb")
    end

    it "should load plugins when plugin_path has a trailing slash" do
      Ohai::Config[:plugin_path] = ["#{tmp}/plugins/"]
      File.stub(:expand_path).with("#{tmp}/plugins/").and_return("#{tmp}/plugins")
      @ohai.load_plugins
    end

    it "should log debug message for already loaded plugin" do
      Ohai::Config[:plugin_path] = ["#{tmp}/plugins",
                                    "#{tmp}/plugins"]
      File.stub(:expand_path).with("#{tmp}/plugins").and_return("#{tmp}/plugins")
      Ohai::Log.should_receive(:debug).with(/Already loaded plugin at/).once
      @ohai.load_plugins
    end

    it "should add loaded plugins to @v6_dependency_solver" do
      Ohai::Config[:plugin_path] = ["#{tmp}/plugins"]
      File.stub(:expand_path).with("#{tmp}/plugins").and_return("#{tmp}/plugins")
      @ohai.load_plugins
      @ohai.v6_dependency_solver.should have_key("#{tmp}/plugins/plgn.rb")
    end
  end

  describe "#run_plugins" do
    before(:all) do
      Ohai::Config[:plugin_path] = ["#{tmp}/plugins"]
    end

    before(:each) do
      @ohai = Ohai::System.new
    end

    describe "when there is exactly one ohai plugin" do
      context "with no collect_data block" do
        before(:each) do
          str = <<EOF
Ohai.plugin do
  provides 'attr'
end
EOF
          file = File.open("#{tmp}/plugins/p.rb", "w+")
          file.write(str)
          file.close

          @plugin = Ohai::Loader.new(@ohai).load_plugin("#{tmp}/plugins/p.rb")
        end

        after(:each) do
          File.delete("#{tmp}/plugins/p.rb")
        end

        it "should not set data" do
          @ohai.run_plugins
          @ohai.data.should be_empty
        end
      end

      context "with no dependencies" do
        before(:each) do
          str = <<EOF
Ohai.plugin do
  provides 'attr'
  collect_data do
    attr "value"
  end
end
EOF
          file = File.open("#{tmp}/plugins/p.rb", "w+")
          file.write(str)
          file.close

          @plugin = Ohai::Loader.new(@ohai).load_plugin("#{tmp}/plugins/p.rb")
        end

        after(:each) do
          File.delete("#{tmp}/plugins/p.rb")
        end

        it "should run exactly once" do
          @ohai.should_receive(:run_plugin).with(@plugin, true).once
          @ohai.run_plugins(true)
        end

        it "should set has_run? to true" do
          @ohai.run_plugins(true)
          @plugin.has_run?.should be_true
        end

        it "should set collected data for the attribute" do
          @ohai.run_plugins
          @ohai.data.should have_key("attr")
          @ohai.data[:attr].should eql("value")
        end
      end

      context "with no provided attributes" do
        before(:each) do
          str = <<EOF
Ohai.plugin do
  collect_data do
    attribute "value"
  end
end
EOF
          file = File.open("#{tmp}/plugins/p.rb", "w+")
          file.write(str)
          file.close

          @plugin = Ohai::Loader.new(@ohai).load_plugin("#{tmp}/plugins/p.rb")
        end

        after(:each) do
          File.delete("#{tmp}/plugins/p.rb")
        end

        it "should not be run" do
          @ohai.should_not_receive(:run_plugin).with(@plugin, false)
          @ohai.run_plugins
        end

        it "should not set has_run? to true" do
          @ohai.run_plugins
          @plugin.has_run?.should be_false
        end

        it "should not add data" do
          @ohai.run_plugins
          @ohai.data.should_not have_key(:attribute)
        end
      end

      context "with no provider for dependency" do
        before(:each) do
          str = <<EOF
Ohai.plugin do
  provides 'exist'
  depends 'nonexist'

  collect_data do
    exist nonexist
  end
end
EOF
          file = File.open("#{tmp}/plugins/p.rb", "w+")
          file.write(str)
          file.close

          @plugin = Ohai::Loader.new(@ohai).load_plugin("#{tmp}/plugins/p.rb")
        end

        after(:each) do
          File.delete("#{tmp}/plugins/p.rb")
        end

        it "should log an error for the missing provider" do
          Ohai::Log.should_receive(:error).with(/NoAttributeError/)
          expect { @ohai.run_plugins }.to raise_error(Ohai::NoAttributeError)
        end

        it "should not run the plugin" do
          expect { @ohai.run_plugins }.to raise_error(Ohai::NoAttributeError)
          @plugin.has_run?.should be_false
        end
      end

      context "which depends on itself" do
        before(:each) do
          str = <<EOF
Ohai.plugin do
  provides 'itself'
  depends 'itself'

  collect_data do
    itself "here i am"
  end
end
EOF
          file = File.open("#{tmp}/plugins/p.rb", "w+")
          file.write(str)
          file.close

          @plugin = Ohai::Loader.new(@ohai).load_plugin("#{tmp}/plugins/p.rb")
        end

        after(:each) do
          File.delete("#{tmp}/plugins/p.rb")
        end

        it "should be run once" do
          @ohai.should_receive(:run_plugin).with(@plugin, true)
          @ohai.run_plugins(true)
        end

        it "should have has_run? set to true" do
          @ohai.run_plugins
          @plugin.has_run?.should be_true
        end
      end
    end

    describe "a dependency cycle of length 2" do
      before(:each) do
        str0 = <<EOF
Ohai.plugin do
  provides 'attr1'
  depends 'attr2'

  collect_data do
    attr1 attr2
  end
end
EOF
        str1 = <<EOF
Ohai.plugin do
  provides 'attr2'
  depends 'attr1'

  collect_data do
    attr2 attr1
  end
end
EOF
        loader = Ohai::Loader.new(@ohai)
        plugins = []
        [str0, str1].each_with_index do |str, idx|
          filename = "#{tmp}/plugins/str#{idx}.rb"
          file = File.open(filename, "w+")
          file.write(str)
          file.close

          plugins << loader.load_plugin(filename)
        end
      end

      after(:each) do
        %w{ str0 str1 }.each do |file|
          File.delete("#{tmp}/plugins/#{file}.rb")
        end
      end

      it "should log an error" do
        Ohai::Log.should_receive(:error).with(/DependencyCycleError/)
        expect { @ohai.run_plugins }.to raise_error(Ohai::DependencyCycleError)
      end
    end

    describe "a dependency cycle of length 3" do
        before(:each) do
          str0 = <<EOF
Ohai.plugin do
  provides 'attr1'
  depends 'attr2'

  collect_data do
    attr1 attr2
  end
end
EOF
          str1 = <<EOF
Ohai.plugin do
  provides 'attr2'
  depends 'attr3'

  collect_data do
    attr2 attr3
  end
end
EOF
          str2 = <<EOF
Ohai.plugin do
  provides 'attr3'
  depends 'attr1'

  collect_data do
    attr3 attr1
  end
end
EOF
        loader = Ohai::Loader.new(@ohai)
        plugins = []
        [str0, str1, str2].each_with_index do |str, idx|
          filename = "#{tmp}/plugins/str#{idx}.rb"
          file = File.open(filename, "w+")
          file.write(str)
          file.close
          
          plugins << loader.load_plugin(filename)
        end
      end
      
      after(:each) do
        %w{ str0 str1 str2 }.each do |file|
          File.delete("#{tmp}/plugins/#{file}.rb")
        end
      end

      it "should log an error" do
        Ohai::Log.should_receive(:error).with(/DependencyCycleError/)
        expect { @ohai.run_plugins }.to raise_error(Ohai::DependencyCycleError)
      end
    end

    describe "correctly defined plugins" do
      before(:each) do
        str0 = <<EOF
Ohai.plugin do
  provides 'ice', 'ice/needs'
  depends 'temperature', 'water/formula'

  collect_data do
    ice Mash.new

    things_to_make_ice = []
    things_to_make_ice << temperature
    things_to_make_ice << water[:formula]

    ice[:needs] = things_to_make_ice
  end
end
EOF
        str1 = <<EOF
Ohai.plugin do
  provides 'temperature'

  collect_data do
    temperature "cold"
  end
end
EOF
        str2 = <<EOF
Ohai.plugin do
  provides 'oxygen', 'hydrogen'

  collect_data do
    oxygen "O"
    hydrogen "H"
  end
end
EOF
        str3 = <<EOF
Ohai.plugin do
  provides 'water', 'water/formula'
  depends 'oxygen', 'hydrogen'

  collect_data do
    water Mash.new

    water[:formula] = hydrogen + "2" + oxygen
  end
end
EOF

        @plugins = []
        loader = Ohai::Loader.new(@ohai)
        [str0, str1, str2, str3].each_with_index do |str, idx|
          filename = "#{tmp}/plugins/str#{idx}.rb"
          file = File.open(filename, "w+")
          file.write(str)
          file.close

          @plugins << loader.load_plugin(filename)
        end
      end

      after(:each) do
        %w{ str0 str1 str2 str3 }.each do |file|
          File.delete("#{tmp}/plugins/#{file}.rb")
        end
      end

      it "should run all the plugins" do
        @ohai.run_plugins
        @plugins.each do |plugin|
          plugin.has_run?.should be_true
        end
      end

      it "should add plugin data" do
        expected_data = Mash.new
      
        # from str2
        expected_data[:hydrogen] = "H"
        expected_data[:oxygen] = "O"

        # from str3
        expected_data[:water] = Mash.new
        expected_data[:water][:formula] = "H2O"

        # from str1
        expected_data[:temperature] = "cold"

        # from str0
        expected_data[:ice] = Mash.new
        expected_data[:ice][:needs] = ["cold", "H2O"]
      
        @ohai.run_plugins
        @ohai.data.sort_by { |key, value| key.to_s }.should eql( expected_data.sort_by { |key, value| key.to_s })
      end
    end

  end
end
