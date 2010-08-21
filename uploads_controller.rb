require 'pp'

class UploadsController < BaseController
  
  before_filter :login_required, :only => [:new, :edit, :update, :destroy, :create, :swfupload]
  before_filter :find_user, :only => [:new, :edit, :index, :slideshow, :swfupload]
  before_filter :require_current_user, :only => [:new, :edit, :update, :destroy, :swfupload]
  skip_before_filter :verify_authenticity_token, :only => [:create] 
  
  

  uses_tiny_mce(:options => AppConfig.simple_mce_options, :only => [:show])

  cache_sweeper :taggable_sweeper, :only => [:create, :update, :destroy]    

  def recent
    @uploads = Upload.recent.paginate(:all, :page => params[:page])
  end
  
  def index
    @user = User.find(params[:user_id])

    cond = Caboose::EZ::Condition.new
    cond.user_id == @user.id
    if params[:tag_name]
      cond.append ['tags.name = ?', params[:tag_name]]
    end
    @folders = Folder.find(:all, :conditions => cond.to_sql, :include => :tags, :page => {:current => params[:page]})
  
    @invite_folder = GroupFolder.find_by_email_and_status(@user.email,'confirmed')
    @tags = Upload.tag_counts :conditions => { :user_id => @user.id }, :limit => 20

    @rss_title = "#{AppConfig.community_name}: #{@user.login}'s files"
    @rss_url = user_uploads_path(@user,:format => :rss)

    respond_to do |format|
      format.html
      format.rss {
        render_rss_feed_for(@uploads,
           { :feed => {:title => @rss_title, :link => url_for(:controller => 'uploads', :action => 'index', :user_id => @user) },
             :item => {:title => :name,
                       :description => Proc.new {|upload| description_for_rss(upload)},
                       :link => Proc.new {|upload| user_upload_url(upload.user, upload)},
                       :pub_date => :created_at} })

      }
      format.xml { render :action => 'index.rxml', :layout => false}
    end
  end

  def show
    @upload = Upload.find(params[:id])
    @user = @upload.user
    if !@upload.view_count
      @upload.view_count = 1
      @upload.save!
    else
      @upload.view_count += 1
      @upload.save!
    end
    @is_current_user = @upload.user.eql?(current_user)
    @comment = Comment.new(params[:comment])
    @comments = @upload.comments.paginate(:per_page => 3, :page => params[:page], :order => 'created_at DESC')
    respond_to do |format|
      format.html
    end
  end


  def new
    @user = User.find(session[:user])
    @upload = Upload.new

    @folders = Folder.find(:all, :include => :group_folders, :conditions => "(group_folders.email = '#{@user.email}' and group_folders.status = 'confirmed' and add_files = '1') or user_id = '#{@user.id}'")
    if params[:inline]
      render :action => 'inline_new', :layout => false
    end
  end

  def edit
    @user = User.find(params[:user_id])
    @folders = Folder.find(:all, :include => :group_folders, :conditions => "(group_folders.email = '#{@user.email}' and group_folders.status = 'confirmed' and add_files = '1') or user_id = '#{@user.id}'")
    @upload = Upload.find(params[:id])
    @access = F_Type.find(:all, :select => "name").map(&:name)
    @user = @upload.user_id
  end

  def create
    @user = current_user
    @upload = Upload.new(params[:upload])
    @upload.name = params[:upload][:name]
    @upload.description = params[:upload][:description]
    @upload.user_id = @user.id
    @upload.folder_id = params[:folder_id]	
    @upload.tag_list = params[:tag_list] || ''
    if (params[:upload][:uploaded_data] && params[:upload][:uploaded_data].content_type =~ /video/)
	    @upload.video = 'video'
	  elsif (@upload.content_type == "application/zip")
	    Upload.build_from_zip(@upload,@user,params[:folder_id])
	  end
   
	  unless (@upload.content_type == "application/zip")
	    if @upload.save
        @upload.convert if (@upload.content_type !~ /image/)
        respond_to do |format|   
          @uploaded_file = Upload.find_all_by_user_id(@user.id)
          if (@upload.content_type =~ /video/)
            @thumbnail = Thumbnail.find_by_id(@upload.thumbnail.to_i)
            @thumbnail.parent_id = @upload.id
            @thumbnail.save
          end
          #start the garbage collector
          GC.start
          flash[:notice] = :file_was_successfully_created.l
          format.html {
            flash[:notice] = :your_file_was_added.l
            render :action => 'inline_new', :layout => false and return if params[:inline]
            
            redirect_to user_folder_url(@upload.folder.user,@upload.folder)
          }
          format.js {
            responds_to_parent do
              render :update do |page|
                page << "upload_image_callback('#{@upload.public_filename()}', '#{@upload.display_name}', '#{@upload.id}');"
              end
            end
          }
        end
      else
        respond_to do |format|
          format.html {
            render :action => 'inline_new', :layout => false and return if params[:inline]
            render :action => "new"
          }
          format.js {
            responds_to_parent do
              render :update do |page|
                page.alert(:sorry_there_was_an_error_uploading_the_file.l)
              end
            end
          }
        end
      end
    else
      respond_to do |format|   
        @uploaded_file = Upload.find_all_by_user_id(@user)
        #start the garbage collector
        GC.start
        flash[:notice] = :file_was_successfully_created.l
        format.html {
          render :action => 'inline_new', :layout => false and return if params[:inline]
          redirect_to user_folder_url(@upload.folder.user, @upload.folder)
        }
        format.js {
          responds_to_parent do
            render :update do |page|
              page << "upload_image_callback('#{@upload.public_filename()}', '#{@upload.display_name}', '#{@upload.id}');"
            end
          end
        }
      end  
    end
  end

  def update
    @upload = Upload.find(params[:id])
    @user = @upload.user_id
    @upload.name = params[:upload][:name]
    @upload.description = params[:upload][:description]
    @upload.folder_id = params[:upload][:folder_id]
    @upload.tag_list = params[:tag_list] || ''
    respond_to do |format|
      if @upload.update_attributes(params[:upload])
      	format.html { redirect_to user_upload_url(@upload.user_id, @upload.id) }
      else
        @user = User.find(params[:user_id])
        @folders = Folder.find(:all, :include => :group_folders, :conditions => "(group_folders.email = '#{@user.email}' and group_folders.status = 'confirmed' and add_files = '1') or user_id = '#{@user.id}'")
        format.html { render :action => "edit" }
      end
    end
  end


  def toggle_featured
    @upload = Upload.find(params[:id])
    if @upload.featurable?
      if @upload.featured?
        @upload.featured = false
        @upload.featured_at = nil
      else
        @upload.featured = true
        @upload.featured_at = Time.now
      end
      @upload.save!
    end
  end
  
  
  def featured
    @uploads = Upload.find(:all, :conditions => "featured = 1", :limit => 5, :order => "featured_at DESC")
    @images = (@uploads.find_all {|file| file.content_type =~ /image/})
    @audios = (@uploads.find_all {|file| file.content_type =~ /audio/})
    @videos = (@uploads.find_all {|file| file.content_type =~ /video/})
  end
  
  
  def toggle_favorite
    @upload = Upload.find(params[:id])
    if @upload.favorited_by(current_user)
      @upload.favorites.find_by_user_id(current_user).destroy
    else
      @upload.favorites.new(:ip_address => request.remote_ip, :user_id => current_user.id).save!
    end
    @upload = Upload.find(params[:id])
  end

  def keep_favorited
    @upload = Upload.find(params[:id])
  end  
  
  def destroy
    @user = User.find(params[:user_id])
    @upload = Upload.find(params[:id])
    if @user.avatar.eql?(@upload)
      @user.avatar = nil
      @user.save!
    end
    @upload.destroy
    flash[:notice] = :your_file_was_deleted.l

    respond_to do |format|
      format.html { redirect_to user_folder_url(@upload.folder.user,@upload.folder)   }
    end
  end

  def all
    @uploads = Upload.public

    if params[:type] == 'new'
      #@uploads = Upload.public.recent
      @uploads = @uploads.find(:all, :order => 'created_at DESC')#, :limit => 5
    elsif params[:type] == 'recentfavorite'
      #@uploads = Favorite.recent_files.collect{|x| x.favoritable}
      #@uploads = Upload.public.recent_favorite
      @uploads = @uploads.find(:all, :joins => "inner join favorites on uploads.id = favorites.favoritable_id", 
              :conditions => ["favorites.favoritable_type = 'Upload' and favorites.created_at > ?", 7.days.ago], :group => "favorites.favoritable_id")
    elsif params[:type] == 'favorite'
      #@uploads = Favorite.files.collect{|x| x.favoritable}
      #@uploads = Upload.public.favorite
      @uploads = @uploads.find(:all, :joins => "inner join favorites on uploads.id = favorites.favoritable_id", 
              :conditions => ["favorites.favoritable_type = 'Upload'"],
              :group => "favorites.favoritable_id")
    else
      #@uploads = Upload.public.popular
      @uploads = @uploads.find(:all, :order => 'view_count DESC')#, :limit => 5
    end

    @images = (@uploads.find_all{|a| a[:content_type] =~ /image/})[0..4].paginate(:page => params[:imagepage], :per_page => 4)
    @audio = (@uploads.find_all{|a| a[:content_type] =~ /audio/})[0..4].paginate(:page => params[:audiopage], :per_page => 4)
    @videos = (@uploads.find_all{|a| a[:content_type] =~ /video/})[0..4].paginate(:page => params[:videopage], :per_page => 4)
    
    respond_to do |format|
      format.html
      
      format.js do
        render :update do |page|
          if params[:imagepage]
            page.replace_html "images", :partial => "files", :locals => {:files => @images}
          elsif params[:audiopage]
            page.replace_html "audios", :partial => "files", :locals => {:files => @audio}
          elsif params[:videopage]
            page.replace_html "videos", :partial => "files", :locals => {:files => @videos}
          end
        end
      end
    end
  end
  
  def download_file
    @file = Upload.find(params[:id])
    send_file("#{RAILS_ROOT}/public"+@file.public_filename, 
      :disposition => 'attachment',
      :encoding => 'utf8', 
      :type => @file.content_type,
      :filename => URI.encode(@file.filename)) 
  end

  def decide_new_upload_path
    #tell the system that you need to redirect to the new_upload_path because user isnt logged in :|
    session[:new_upload_path_needed] = true
    redirect_to '/login'
  end
  
 
 
  protected

  def description_for_rss(upload)
    "<a href='#{user_upload_url(upload.user, upload)}' title='#{upload.name}'><img src='#{upload.public_filename(:large)}' alt='#{upload.name}' /><br />#{upload.description}</a>"
  end
  
end
