# Copyright 2011-2013, The Trustees of Indiana University and Northwestern
#   University.  Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
# 
# You may obtain a copy of the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software distributed 
#   under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
#   CONDITIONS OF ANY KIND, either express or implied. See the License for the 
#   specific language governing permissions and limitations under the License.
# ---  END LICENSE_HEADER BLOCK  ---

require 'spec_helper'

describe MasterFile do
#  describe "container" do
#    it "should set relationships on self and container" do
#      mf = MasterFile.new
#      mo = MediaObject.new
#      mo.save(validate: false)
#      mf.relationships_by_name[:self]["part_of"].size.should == 0
#      mo.relationships_by_name[:self]["parts"].size.should == 0
#      mf.mediaobject = mo
#      mf.relationships_by_name[:self]["part_of"].size.should == 1
#      mf.relationships_by_name[:self]["part_of"].first.should eq "info:fedora/#{mo.pid}"
#      mo.relationships_by_name[:self]["parts"].size.should == 1
#      mo.relationships_by_name[:self]["parts"].first.should eq "info:fedora/#{mf.pid}"
#      mf.relationships_are_dirty.should be true
#      mo.relationships_are_dirty.should be true
#    end
#  end

  describe "validations" do
    subject {MasterFile.new}
    it {should validate_presence_of(:workflow_name)}
    it {should ensure_inclusion_of(:workflow_name).in_array(MasterFile::WORKFLOWS)}
  end

  describe "locations" do
    subject { 
      mf = MasterFile.new 
      mf.file_location = '/foo/bar/baz/quux.mp4'
      mf.save
      mf
    }

    it "should know where its (local) masterfile is" do
      subject.file_location.should == '/foo/bar/baz/quux.mp4'
      subject.absolute_location.should == 'file:///foo/bar/baz/quux.mp4'
    end

    it "should know where its (Samba remote) masterfile is" do
      Avalon::FileResolver.any_instance.stub(:mounts) { 
        ["//user@some.server.at.an.example.edu/stuff on /foo/bar (smbfs, nodev, nosuid, mounted by user)"]
      }

      subject.absolute_location.should == 'smb://some.server.at.an.example.edu/stuff/baz/quux.mp4'
    end

    it "should know where its (CIFS remote) masterfile is" do
      Avalon::FileResolver.any_instance.stub(:mounts) { 
        ["//user@some.server.at.an.example.edu/stuff on /foo/bar (cifs, nodev, nosuid, mounted by user)"]
      }

      subject.absolute_location.should == 'cifs://some.server.at.an.example.edu/stuff/baz/quux.mp4'
    end

    it "should know where its (NFS remote) masterfile is" do
      Avalon::FileResolver.any_instance.stub(:mounts) { 
        ["some.server.at.an.example.edu:/stuff on /foo/bar (nfs, nodev, nosuid, mounted by user)"]
      }

      subject.absolute_location.should == 'nfs://some.server.at.an.example.edu/stuff/baz/quux.mp4'
    end

    it "should follow the file to a new location" do
      subject.absolute_location.should == 'file:///foo/bar/baz/quux.mp4'
      subject.file_location = "/tmp/baz/quux.mp4"
      subject.absolute_location.should == 'file:///tmp/baz/quux.mp4'
    end

    it "should accept configurable overrides" do
      Avalon::FileResolver.any_instance.stub(:overrides) {
        { '/foo/bar/' => 'http://repository.example.edu/foothings/' }
      }
      subject.absolute_location.should == 'http://repository.example.edu/foothings/baz/quux.mp4'
    end
  end

  describe "masterfiles=" do
    it "should set hasDerivation relationships on self" do
      derivative = Derivative.new
      mf = FactoryGirl.build(:master_file)
      mf.save
      derivative.save

      mf.relationships(:is_derivation_of).size.should == 0

      mf.derivatives += [derivative]

      derivative.relationships(:is_derivation_of).size.should == 1
      derivative.relationships(:is_derivation_of).first.should == mf.internal_uri

      #derivative.relationships_are_dirty.should be true
    end
  end

  describe '#finished_processing?' do
    describe 'classifying statuses' do
      let(:master_file){ MasterFile.new }
      it 'returns true for stopped' do
        master_file.status_code = ['STOPPED']
        master_file.finished_processing?.should be_true
      end
      it 'returns true for succeeded' do
        master_file.status_code = ['SUCCEEDED']
        master_file.finished_processing?.should be_true
      end
      it 'returns true for failed' do
        master_file.status_code = ['FAILED']
        master_file.finished_processing?.should be_true
      end
    end
  end

  describe "delete" do
    subject(:masterfile) { derivative.masterfile }
    let(:derivative) {FactoryGirl.create(:derivative)}
    it "should delete (VOV-1805)" do
      Rubyhorn.stub_chain(:client,:delete_track).and_return("http://test.com/retract_rtmp.xml")
      Rubyhorn.stub_chain(:client,:delete_hls_track).and_return("http://test.com/retract_hls.xml")
      masterfile
      expect { masterfile.delete }.to change { MasterFile.all.count }.by(-1)
    end

    it "should delete with a nil parent (VOV-1357)" do
      pending "bugfix"      
      masterfile.mediaobject = nil
      masterfile.save
      expect { masterfile.delete }.to change { MasterFile.all.count }.by(-1)
    end
  end

  describe "image_offset" do
    subject(:master_file) {FactoryGirl.create(:master_file, duration: (rand(21600000)+60000).to_s )}

    describe "milliseconds" do
      it "should accept a value" do
        offset = master_file.duration.to_i / 2
        master_file.poster_offset = offset
        master_file.poster_offset.should == offset.to_s
        master_file.should be_valid
      end

      it "should complain if value < 0" do
        master_file.poster_offset = -1
        master_file.should_not be_valid
        master_file.errors[:poster_offset].first.should == "must be between 0 and #{master_file.duration}"
      end

      it "should complain if value > duration" do
        offset = master_file.duration.to_i + rand(32514) + 500
        master_file.poster_offset = offset
        master_file.should_not be_valid
        master_file.errors[:poster_offset].first.should == "must be between 0 and #{master_file.duration}"
      end
    end

    describe "hh:mm:ss.sss" do
      it "should accept a value" do
        offset = master_file.duration.to_i / 2
        master_file.poster_offset = offset.to_hms
        master_file.poster_offset.should == offset.to_s
        master_file.should be_valid
      end

      it "should complain if value > duration" do
        offset = master_file.duration.to_i + rand(32514) + 500
        master_file.poster_offset = offset.to_hms
        master_file.should_not be_valid
        master_file.errors[:poster_offset].first.should == "must be between 0 and #{master_file.duration}"
      end
    end

    describe "update images" do
      it "should update on save" do
        MasterFile.should_receive(:extract_still).with(master_file.pid,{type:'both',offset:'12345'})
        master_file.poster_offset = 12345
        master_file.save
      end
    end
  end

  describe "#set_workflow" do
    let (:master_file) {MasterFile.new}
    describe "custom workflow" do
      it "should not use the passed workflow if it is not in the WORKFLOWS list" do
        master_file.file_format = 'Moving image'
        master_file.set_workflow('bad-workflow')
        master_file.workflow_name.should == 'avalon'
      end 
      it "should use the passed workflow if it is in the WORKFLOWS list" do
        master_file.file_format = 'Moving image'
        master_file.set_workflow(MasterFile::WORKFLOWS.first)
        master_file.workflow_name.should == MasterFile::WORKFLOWS.first
      end 
    end
    describe "video" do
      it "should use the avalon workflow" do
        master_file.file_format = 'Moving image'
        master_file.set_workflow
        master_file.workflow_name.should == 'avalon'
      end 
    end
    describe "audio" do
      it "should use the fullaudio workflow" do
        master_file.file_format = 'Sound'
        master_file.set_workflow
        master_file.workflow_name.should == 'fullaudio'
      end
    end
    describe "unknown format" do
      it "should set workflow_name to nil" do
        master_file.file_format = 'Unknown'
        master_file.set_workflow
        master_file.workflow_name.should == nil
      end
    end
  end

  describe '#setContent' do
    describe "uploaded file" do
      let(:fixture)    { File.expand_path('../../fixtures/videoshort.mp4',__FILE__) }
      let(:original)   { File.basename(fixture) }
      let(:tempdir)    { File.realpath('/tmp') }
      let(:tempfile)   { File.join(tempdir, 'RackMultipart20130816-2519-y2wzc7') }
      let(:media_path) { File.expand_path("../../masterfiles-#{SecureRandom.uuid}",__FILE__)}
      let(:upload)     { ActionDispatch::Http::UploadedFile.new :tempfile => File.open(tempfile), :filename => original, :type => 'video/mp4' }
      subject { 
        mf = MasterFile.new
        mf.setContent(upload)
        mf
      }

      before(:each) do
        @old_media_path = Avalon::Configuration['matterhorn']['media_path']
        FileUtils.mkdir_p media_path
        FileUtils.cp fixture, tempfile
      end

      after(:each) do
        Avalon::Configuration['matterhorn']['media_path'] = @old_media_path
        File.unlink subject.file_location
        FileUtils.rm_rf media_path
      end

      it "should rename an uploaded file in place" do
        Avalon::Configuration['matterhorn'].delete('media_path')
        subject.file_location.should == File.join(tempdir,original)
      end

      it "should copy an uploaded file to the Matterhorn media path" do
        Avalon::Configuration['matterhorn']['media_path'] = media_path
        subject.file_location.should == File.join(media_path,original)
      end
    end
  end
  
end
