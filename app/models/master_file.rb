class MasterFile < FileAsset
  include ActiveFedora::Relationships

  has_relationship "part_of", :is_part_of
  has_relationship "derivatives", :has_derivation
  has_metadata name: 'descMetadata', type: DublinCoreDocument
  has_metadata name: 'statusMetadata', :type => ActiveFedora::SimpleDatastream do |d|
    d.field :percent_complete, :string
    d.field :status_code, :string
  end

  belongs_to :mediaobject, :class_name=>'MediaObject', :property=>:is_part_of
  
  delegate :workflow_id, to: :descMetadata, at: [:source], unique: true
  #delegate :description, to: :descMetadata
  delegate :url, to: :descMetadata, at: [:identifier]
  delegate :size, to: :descMetadata, at: [:extent]
  delegate :media_type, to: :descMetadata, at: [:dc_type]
  delegate :media_format, to: :descMetadata, at: [:medium]

  delegate_to 'statusMetadata', [:percent_complete, :status_code]

    # First and simplest test - make sure that the uploaded file does not exceed the
    # limits of the system. For now this is hard coded but should probably eventually
    # be set up in a configuration file somewhere
    #
    # 250 MB is the file limit for now
    MAXIMUM_UPLOAD_SIZE = (2**20) * 250

  AUDIO_TYPES = ["audio/vnd.wave", "audio/mpeg", "audio/mp3", "audio/mp4", "audio/wav",
      "audio/x-wav"]
  VIDEO_TYPES = ["application/mp4", "video/mpeg", "video/mpeg2", "video/mp4", "video/quicktime", "video/avi"]
  UNKNOWN_TYPES = ["application/octet-stream", "application/x-upload-data"]

  def container= obj
    super obj
    self.container.add_relationship(:has_part, self)
  end

  def save
    super
    unless self.container.nil?
      self.container.save(validate: false)
    end
  end  

  def destroy
    parent = self.container
    parent.parts_remove master_file
    parent.save(validate: false)

    Rubyhorn.client.stop(master_file.source.first)

    master_file.delete
  end

  def content= file
    self.media_type = determine_format file
    saveOriginal file
  end

  def workflow_id
    source.first
  end

  def mediapackage_id
    matterhorn_response = Rubyhorn.client.instance_xml(source.first)
    matterhorn_response.workflow.mediapackage.id.first
  end

  # A hacky way to handle the description for now. This should probably be refactored
  # to stop pulling if the status is stopped or completed
  #def status_description
    #unless source.nil? or source.empty?
      #refresh_status
    #else
      #descMetadata.description = "Status is currently unavailable"
    #end
    #descMetadata.description.first
  #end

  #def exceeds_upload_limit?(size)
    #size > MAXIMUM_UPLOAD_SIZE
  #end

  def status_description
    case self.status_code.first 
      when "INSTANTIATED"
        "Preparing file for conversion"
      when "RUNNING"
        "Creating derivatives"
      when "SUCCEEDED"
        "Processing is complete"
      when "FAILED"
        "File(s) could not be processed"
      when "STOPPED"
        "Processing has been stopped"
      else
        "No file(s) uploaded"
      end
  end  

  def updateProgress
    matterhorn_response = Rubyhorn.client.instance_xml(workflow_id)

    @masterfile.percent_complete = percent_complete(matterhorn_response)
    @masterfile.status_code = matterhorn_response.workflow.state[0]
  end

  protected
  def refresh_status
    matterhorn_response = Rubyhorn.client.instance_xml(source[0])
    status = matterhorn_response.workflow.state[0]
 
    descMetadata.description = case status
      when "INSTANTIATED"
        "Preparing file for conversion"
      when "RUNNING"
        "Creating derivatives"
      when "SUCCEEDED"
        "Processing is complete"
      when "FAILED"
        "File(s) could not be processed"
      when "STOPPED"
        "Processing has been stopped"
      else
        "No file(s) uploaded"
      end
    save
  end

  def percent_complete matterhorn_response
    totalOperations = matterhorn_response.workflow.operations.operation.length
    finishedOperations = 0
    matterhorn_response.workflow.operations.operation.operationState.each {|state| finishedOperations += 1 if state == "SUCCEEDED" || state == "SKIPPED"}
    percent = finishedOperations * 100 / totalOperations
    puts "percent_complete #{percent}"
    percent.to_s
  end

  def determine_format(file)
    upload_format = 'Moving image' if MasterFile::VIDEO_TYPES.include?(file.content_type)
    upload_format = 'Sound' if MasterFile::AUDIO_TYPES.include?(file.content_type)

    # If the content type cannot be inferred from the MIME type fall back on the
    # list of unknown types. This is different than a generic fallback because it
    # is skipped for known invalid extensions like application/pdf
    upload_format = determine_format_by_extension(file) if MasterFile::UNKNOWN_TYPES.include?(file.content_type)
    logger.info "<< Uploaded file appears to be #{@upload_format} >>"
    return upload_format
  end

  def determine_format_by_extension(file)
    audio_extensions = ["mp3", "wav", "aac", "flac"]
    video_extensions = ["mpeg4", "mp4", "avi", "mov"]

    logger.debug "<< Using fallback method to guess the format >>"

    extension = file.original_filename.split(".").last.downcase
    logger.debug "<< File extension is #{extension} >>"

    # Default to unknown
    format = 'Unknown'
    format = 'Moving image' if video_extensions.include?(extension)
    format = 'Sound' if audio_extensions.include?(extension)

    return format
  end

  def sendToMatterhorn
    args = {"title" => self.pid , "flavor" => "presenter/source", "filename" => self.content.basename}
    if self.media_format == 'Sound'
      args['workflow'] = "fullaudio"
    elsif self.media_format == 'Moving image'
      args['workflow'] = "hydrant"
    end
    logger.debug "<< Calling Matterhorn with arguments: #{args} >>"
    workflow_doc = Rubyhorn.client.addMediaPackage(self.content, args)
    #master_file.description = "File is being processed"

    # I don't know why this has to be double escaped with two arrays
    master_file.source = workflow_doc.workflow.id[0]
    master_file.save
  end

  def saveOriginal file
    public_dir_path = "#{Rails.root}/public/"
    new_dir_path = public_dir_path + 'media_objects/' + params[:container_id].gsub(":", "_") + "/"
    new_file_path = new_dir_path + file.original_filename
    FileUtils.mkdir_p new_dir_path unless File.exists?(new_dir_path)
    FileUtils.rm new_file_path if File.exists?(new_file_path)
    FileUtils.cp file.tempfile, new_file_path

    self.url = new_file_path[public_dir_path.length - 1, new_file_path.length - 1]

    logger.debug "<< Filesize #{ file.size.to_s } >>"
    self.size = file.size.to_s

    #FIXME next line
    #apply_depositor_metadata(master_file)

    self.container = MediaObject.find(params[:container_id])

    # If redirect_params has not been set, use {:action=>:index}
    logger.debug "Created #{master_file.pid}."
  end

end
