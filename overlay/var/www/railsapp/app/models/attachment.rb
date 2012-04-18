# Redmine - project management software
# Copyright (C) 2006-2012  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require "digest/md5"

class Attachment < ActiveRecord::Base
  belongs_to :container, :polymorphic => true
  belongs_to :author, :class_name => "User", :foreign_key => "author_id"

  validates_presence_of :filename, :author
  validates_length_of :filename, :maximum => 255
  validates_length_of :disk_filename, :maximum => 255
  validate :validate_max_file_size

  acts_as_event :title => :filename,
                :url => Proc.new {|o| {:controller => 'attachments', :action => 'download', :id => o.id, :filename => o.filename}}

  acts_as_activity_provider :type => 'files',
                            :permission => :view_files,
                            :author_key => :author_id,
                            :find_options => {:select => "#{Attachment.table_name}.*",
                                              :joins => "LEFT JOIN #{Version.table_name} ON #{Attachment.table_name}.container_type='Version' AND #{Version.table_name}.id = #{Attachment.table_name}.container_id " +
                                                        "LEFT JOIN #{Project.table_name} ON #{Version.table_name}.project_id = #{Project.table_name}.id OR ( #{Attachment.table_name}.container_type='Project' AND #{Attachment.table_name}.container_id = #{Project.table_name}.id )"}

  acts_as_activity_provider :type => 'documents',
                            :permission => :view_documents,
                            :author_key => :author_id,
                            :find_options => {:select => "#{Attachment.table_name}.*",
                                              :joins => "LEFT JOIN #{Document.table_name} ON #{Attachment.table_name}.container_type='Document' AND #{Document.table_name}.id = #{Attachment.table_name}.container_id " +
                                                        "LEFT JOIN #{Project.table_name} ON #{Document.table_name}.project_id = #{Project.table_name}.id"}

  cattr_accessor :storage_path
  @@storage_path = Redmine::Configuration['attachments_storage_path'] || "#{Rails.root}/files"

  before_save :files_to_final_location
  after_destroy :delete_from_disk

  def container_with_blank_type_check
    if container_type.blank?
      nil
    else
      container_without_blank_type_check
    end
  end
  alias_method_chain :container, :blank_type_check unless method_defined?(:container_without_blank_type_check)

  # Returns an unsaved copy of the attachment
  def copy(attributes=nil)
    copy = self.class.new
    copy.attributes = self.attributes.dup.except("id", "downloads")
    copy.attributes = attributes if attributes
    copy
  end

  def validate_max_file_size
    if @temp_file && self.filesize > Setting.attachment_max_size.to_i.kilobytes
      errors.add(:base, l(:error_attachment_too_big, :max_size => Setting.attachment_max_size.to_i.kilobytes))
    end
  end

  def file=(incoming_file)
    unless incoming_file.nil?
      @temp_file = incoming_file
      if @temp_file.size > 0
        if @temp_file.respond_to?(:original_filename)
          self.filename = @temp_file.original_filename
          self.filename.force_encoding("UTF-8") if filename.respond_to?(:force_encoding)
        end
        if @temp_file.respond_to?(:content_type)
          self.content_type = @temp_file.content_type.to_s.chomp
        end
        if content_type.blank? && filename.present?
          self.content_type = Redmine::MimeType.of(filename)
        end
        self.filesize = @temp_file.size
      end
    end
  end

  def file
    nil
  end

  def filename=(arg)
    write_attribute :filename, sanitize_filename(arg.to_s)
    if new_record? && disk_filename.blank?
      self.disk_filename = Attachment.disk_filename(filename)
    end
    filename
  end

  # Copies the temporary file to its final location
  # and computes its MD5 hash
  def files_to_final_location
    if @temp_file && (@temp_file.size > 0)
      logger.info("Saving attachment '#{self.diskfile}' (#{@temp_file.size} bytes)")
      md5 = Digest::MD5.new
      File.open(diskfile, "wb") do |f|
        buffer = ""
        while (buffer = @temp_file.read(8192))
          f.write(buffer)
          md5.update(buffer)
        end
      end
      self.digest = md5.hexdigest
    end
    @temp_file = nil
    # Don't save the content type if it's longer than the authorized length
    if self.content_type && self.content_type.length > 255
      self.content_type = nil
    end
  end

  # Deletes the file from the file system if it's not referenced by other attachments
  def delete_from_disk
    if Attachment.first(:conditions => ["disk_filename = ? AND id <> ?", disk_filename, id]).nil?
      delete_from_disk!
    end
  end

  # Returns file's location on disk
  def diskfile
    "#{@@storage_path}/#{self.disk_filename}"
  end

  def increment_download
    increment!(:downloads)
  end

  def project
    container.try(:project)
  end

  def visible?(user=User.current)
    container && container.attachments_visible?(user)
  end

  def deletable?(user=User.current)
    container && container.attachments_deletable?(user)
  end

  def image?
    self.filename =~ /\.(bmp|gif|jpg|jpe|jpeg|png)$/i
  end

  def is_text?
    Redmine::MimeType.is_type?('text', filename)
  end

  def is_diff?
    self.filename =~ /\.(patch|diff)$/i
  end

  # Returns true if the file is readable
  def readable?
    File.readable?(diskfile)
  end

  # Returns the attachment token
  def token
    "#{id}.#{digest}"
  end

  # Finds an attachment that matches the given token and that has no container
  def self.find_by_token(token)
    if token.to_s =~ /^(\d+)\.([0-9a-f]+)$/
      attachment_id, attachment_digest = $1, $2
      attachment = Attachment.first(:conditions => {:id => attachment_id, :digest => attachment_digest})
      if attachment && attachment.container.nil?
        attachment
      end
    end
  end

  # Bulk attaches a set of files to an object
  #
  # Returns a Hash of the results:
  # :files => array of the attached files
  # :unsaved => array of the files that could not be attached
  def self.attach_files(obj, attachments)
    result = obj.save_attachments(attachments, User.current)
    obj.attach_saved_attachments
    result
  end

  def self.latest_attach(attachments, filename)
    attachments.sort_by(&:created_on).reverse.detect {
      |att| att.filename.downcase == filename.downcase
     }
  end

  def self.prune(age=1.day)
    attachments = Attachment.all(:conditions => ["created_on < ? AND (container_type IS NULL OR container_type = '')", Time.now - age])
    attachments.each(&:destroy)
  end

  private

  # Physically deletes the file from the file system
  def delete_from_disk!
    if disk_filename.present? && File.exist?(diskfile)
      File.delete(diskfile)
    end
  end

  def sanitize_filename(value)
    # get only the filename, not the whole path
    just_filename = value.gsub(/^.*(\\|\/)/, '')

    # Finally, replace invalid characters with underscore
    @filename = just_filename.gsub(/[\/\?\%\*\:\|\"\'<>]+/, '_')
  end

  # Returns an ASCII or hashed filename
  def self.disk_filename(filename)
    timestamp = DateTime.now.strftime("%y%m%d%H%M%S")
    ascii = ''
    if filename =~ %r{^[a-zA-Z0-9_\.\-]*$}
      ascii = filename
    else
      ascii = Digest::MD5.hexdigest(filename)
      # keep the extension if any
      ascii << $1 if filename =~ %r{(\.[a-zA-Z0-9]+)$}
    end
    while File.exist?(File.join(@@storage_path, "#{timestamp}_#{ascii}"))
      timestamp.succ!
    end
    "#{timestamp}_#{ascii}"
  end
end
