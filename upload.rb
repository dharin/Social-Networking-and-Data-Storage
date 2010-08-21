class Upload < ActiveRecord::Base

  has_attachment  :storage => :file_system,
                  :max_size => 128.megabytes,
                  :path_prefix => "public/uploads",         
                  :thumbnails => { :tiny => '50x50>', :thumb => '75x75>', :medium => '300x300>'},
                  :processor => 'Rmagick',
                  :thumbnail_class => Thumbnail

  validates_presence_of :folder_id  
  validates_presence_of :name

  
  require 'rubygems'
  require 'zip/zip'
  require 'zip/zipfilesystem'
  require 'fileutils'
  require 'mime/types'
	
  has_many :thumbnails, :foreign_key => 'parent_id'
  belongs_to :user
  belongs_to :folder
  
  acts_as_taggable
  acts_as_commentable
  
  before_create :save_thumbnail
	
  attr_accessor :video 

  acts_as_state_machine :initial => :pending
  
  state :pending
  state :converting
  state :converted, :enter => :set_new_filename
  state :error

  event :convert do
    transitions :from => :pending, :to => :converting
  end
 
  event :converted do
    transitions :from => :converting, :to => :converted
  end

  event :failure do
    transitions :from => :converting, :to => :error
  end
	
  has_many :favorites, :as => :favoritable, :dependent => :destroy 

  #named scopes for Upload
  named_scope :recent, :order => 'uploads.created_at DESC', :limit => 5

  named_scope :popular, :order => 'view_count DESC', :limit => 4

  named_scope :featured, :conditions => ["featured = 1"], :limit => 5, :order => "created_at DESC"

  named_scope :public, :joins => [:folder], :conditions => ["folder_id = folders.id and folders.f_type_id = 1"]

  named_scope :audio, :conditions => ["content_type like '%%audio%%'"]

  named_scope :images, :conditions => ["content_type like '%%image%%'"]

  named_scope :video, :conditions => ["content_type like '%%video%%'"]# 

  named_scope :recent_favorite, :joins => "inner join favorites on uploads.id = favorites.favoritable_id", 
              :conditions => ["favorites.favoritable_type = 'Upload' and favorites.created_at > ?", 7.days.ago], :group => "favorites.favoritable_id"

  named_scope :favorite, :joins => "inner join favorites on uploads.id = favorites.favoritable_id", 
              :conditions => ["favorites.favoritable_type = 'Upload'"],
              :group => "favorites.favoritable_id"
  
  named_scope :tagged_with, lambda {|tag_name| {:conditions => ["tags.name = ?", tag_name], :include => :tags}}
	
  named_scope :viewable_by, lambda {|user| {:conditions => ["folders.f_type_id = 1 or group_folders.email = ? or uploads.user_id = ?", user.email, user.id], :include => {:folder => :group_folders}}}
	
  define_index do
    indexes :name, description
    indexes folder.f_type_id, :as => :type
	  
    set_property :min_infix_len => 1
    set_property :enable_star => true
    set_property :delta => true
	  
    has :id
  end
	
  #turn off attachment_fu's auto file renaming 
  #when you change the value of the filename field
  def rename_file
    true
  end
	
  def owner
    self.user
  end
	
  def self.build_from_zip(ss,user,folder_id)
    zipfile = Zip::ZipFile.open(ss.temp_path)
    
    zipfile.each do |entry|
      if entry.directory?
        debugger
        next
      elsif entry.name.include?("/")
        debugger
        next
      else
        screen = Upload.new
        screen.name = ss.name
        screen.description = ss.description unless (ss.description.nil?)
        screen.filename = entry.name
        screen.user_id = user.id
        screen.folder_id = folder_id
        screen.temp_data = zipfile.read(entry.name)
        mime = MIME::Types.type_for(entry.name)[0]

        screen.video = 'video' if (mime.content_type =~ /video/)

        screen.content_type = mime.content_type unless mime.blank?
        screen.save!
        
        if (mime.content_type !~ /image/) && (mime.content_type !~ /zip/)
          screen.convert
#        elsif (mime.content_type =~ /zip/)
#          self.build_from_zip(entry,screen.user,screen.folder_id)
        end  
      end
    end
  end
	
  def public?
    self.folder.f_type_id == 1
  end
	
  def private?
    self.folder.f_type_id == 3
  end
	
  def viewable_by?(user)
    self.folder.viewable_by?(user)
  end
	
  def favorited_by(user)
    !!self.favorites.find_by_user_id(user.id)
  end
	
  def featurable?
    !!(folder.f_type_id == 1)
  end
	
  # This method is called from the controller and takes care of the converting
  def convert
    self.convert!
    #spawn a new thread to handle conversion
    spawn do
      success = system(convert_command)
      logger.debug 'Converting File: ' + success.to_s
      if success && $?.exitstatus == 0
        self.converted!
        delete_file
      else
        self.failure!
      end
    end #spawn thread
  end

  def save_thumbnail
    #@video is an attribute of an upload which is set in the controller.
    if @video
      logger.info "Saving thumbnail of Video..."
      t = Thumbnail.create!(self.temp_path)
      self.thumbnail = t.id
      t
    end  
  end

  def delete_file
    if @video
      fname = "." + "#{self.id}" + ".flv"
    else
      fname = "." + "#{self.id}" + ".mp3"
    end  
    FileUtils.rm("#{ RAILS_ROOT + '/public' + public_filename.gsub(/#{fname}/,'')}")
  end


  protected
  
  def convert_command
    #construct new file extension
    if @video
      flv =  "." + id.to_s + ".flv"

      #build the command to execute ffmpeg
      command = <<-end_command
        ffmpeg -i #{ RAILS_ROOT + '/public' + public_filename } -ar 22050 -s 720x480 -f flv -y #{ RAILS_ROOT + '/public' + public_filename + flv }
      end_command
    
      logger.debug "Converting video...command: " + command
      command
    else
      mp3 =  "." + id.to_s + ".mp3"
      
      #build the command to execute ffmpeg
      command = <<-end_command
        ffmpeg -i #{ RAILS_ROOT + '/public' + public_filename } -ar 22050 -s 720x480 -f mp3 -y #{ RAILS_ROOT + '/public' + public_filename + mp3 }
      end_command
    
      logger.debug "Converting audio...command: " + command
      command
    end
  end
  
  # This updates the stored filename with the new flash video file
  def set_new_filename
    if @video
      update_attribute(:filename, "#{filename}.#{id}.flv")
      update_attribute(:content_type, "application/x-flash-video")
    else
      update_attribute(:filename, "#{filename}.#{id}.mp3")
      update_attribute(:content_type, "application/x-flash-audio")
    end  
  end
	
  def validate
    @usage = 0
    @uploads = Upload.find_all_by_user_id(self.user_id)
    @uploads.each do |@uploaded|
      @usage += @uploaded.size
    end
    if (self.filename && self.size == 1.kilobytes )
      errors.add_to_base("File size is almost 1 KB, please choose file having size more them 1 KB.")
    else
      if (self.filename && self.size > AppConfig.MAX_UPLOAD_SIZE.megabytes )
        errors.add_to_base("File size is greater than 128MB, please choose file with less size.")
      end
      if (self.filename &&  ((self.size + @usage) > 5368709120))
  	    @remain = 5368709120 - self.size
  	    errors.add_to_base("You can upload up to 5 GB only! You have only #{@remain} bytes left.")
  	  end
  	  if self.filename && (self.content_type.match(/video/).nil? ^ self.content_type.match(/audio/).nil? ^ self.content_type.match(/image/).nil?)
        errors.add_to_base("You can upload only videos, audios and images (AVI, WMV, FLV, MOV, WMA, MP3, MP4, MPEG, BMA, PNG, JPG, JPEG, GIF etc..)")
      end
      errors.add_to_base("You must choose a file to upload.") unless self.filename
    end
  end
end
