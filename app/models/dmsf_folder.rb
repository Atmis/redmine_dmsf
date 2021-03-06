# encoding: utf-8
#
# Redmine plugin for Document Management System "Features"
#
# Copyright (C) 2011    Vít Jonáš <vit.jonas@gmail.com>
# Copyright (C) 2011-17 Karel Pičman <karel.picman@konton.com>
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

class DmsfFolder < ActiveRecord::Base
  unloadable

  include RedmineDmsf::Lockable

  belongs_to :project
  belongs_to :dmsf_folder
  belongs_to :deleted_by_user, :class_name => 'User', :foreign_key => 'deleted_by_user_id'
  belongs_to :user

  has_many :dmsf_folders, -> { order(:title) }, :dependent => :destroy
  has_many :dmsf_files, :dependent => :destroy
  has_many :folder_links, -> { where(:target_type => 'DmsfFolder').order(:name) },
    :class_name => 'DmsfLink', :foreign_key => 'dmsf_folder_id', :dependent => :destroy
  has_many :file_links, -> { where :target_type => 'DmsfFile' },
    :class_name => 'DmsfLink', :foreign_key => 'dmsf_folder_id', :dependent => :destroy
  has_many :url_links, -> { where :target_type => 'DmsfUrl' },
    :class_name => 'DmsfLink', :foreign_key => 'dmsf_folder_id', :dependent => :destroy
  has_many :dmsf_links, :dependent => :destroy
  has_many :referenced_links, -> { where :target_type => 'DmsfFolder' },
    :class_name => 'DmsfLink', :foreign_key => 'target_id', :dependent => :destroy
  has_many :locks, -> { where(entity_type:  1).order("#{DmsfLock.table_name}.updated_at DESC") },
    :class_name => 'DmsfLock', :foreign_key => 'entity_id', :dependent => :destroy

  INVALID_CHARACTERS = /\A[^\/\\\?":<>#%\*]*\z/.freeze
  STATUS_DELETED = 1.freeze
  STATUS_ACTIVE = 0.freeze
  AVAILABLE_COLUMNS = %w(id title extension size modified version workflow author).freeze
  DEFAULT_COLUMNS = %w(title size modified version workflow author).freeze

  scope :visible, -> { where(:deleted => STATUS_ACTIVE) }
  scope :deleted, -> { where(:deleted => STATUS_DELETED) }

  acts_as_customizable

  acts_as_searchable :columns => ["#{self.table_name}.title", "#{self.table_name}.description"],
        :project_key => 'project_id',
        :date_column => 'updated_at',
        :permission => :view_dmsf_files,
        :scope => self.joins(:project)

  acts_as_event :title => Proc.new {|o| o.title},
          :description => Proc.new {|o| o.description },
          :url => Proc.new {|o| {:controller => 'dmsf', :action => 'show', :id => o.project, :folder_id => o}},
          :datetime => Proc.new {|o| o.updated_at },
          :author => Proc.new {|o| o.user }

  validates :title, :presence => true
  validates_uniqueness_of :title, :scope => [:dmsf_folder_id, :project_id, :deleted],
    conditions: -> { where(:deleted => STATUS_ACTIVE) }
  validates_format_of :title, :with => INVALID_CHARACTERS,
    :message => l(:error_contains_invalid_character)
  validate :check_cycle

  before_create :default_values
  def default_values
    @notifications = Setting.plugin_redmine_dmsf['dmsf_default_notifications']
    if @notifications == '1'
      self.notification = true
    else
      self.notification = nil
    end
  end

  def check_cycle
    folders = []
    self.dmsf_folders.each {|f| folders.push(f)}
    self.dmsf_folders.each do |folder|
      if folder == self.dmsf_folder
        errors.add(:folder, l(:error_create_cycle_in_folder_dependency))
        return false
      end
      folder.dmsf_folders.each {|f| folders.push(f)}
    end
    return true
  end

  def self.find_by_title(project, folder, title)
    if folder
      visible.where(:project_id => project.id, :dmsf_folder_id => nil, :title => title).first
    else
      visible.where(:project_id => project.id, :dmsf_folder_id => folder.id, :title => title).first
    end
  end

  def delete(commit)
    if self.locked?
      errors[:base] << l(:error_folder_is_locked)
      return false
    elsif !self.dmsf_folders.visible.empty? || !self.dmsf_files.visible.empty?
      errors[:base] << l(:error_folder_is_not_empty)
      return false
    end
    if commit
      self.destroy
    else
      self.deleted = STATUS_DELETED
      self.deleted_by_user = User.current
      self.save
    end
  end

  def deleted?
    self.deleted == STATUS_DELETED
  end

  def restore
    if self.dmsf_folder_id && (self.dmsf_folder.nil? || self.dmsf_folder.deleted?)
      errors[:base] << l(:error_parent_folder)
      return false
    end
    self.deleted = STATUS_ACTIVE
    self.deleted_by_user = nil
    self.save
  end

  def dmsf_path
    folder = self
    path = []
    while folder
      path.unshift(folder)
      folder = folder.dmsf_folder
    end
    path
  end

  def dmsf_path_str
    path = self.dmsf_path
    string_path = path.map { |element| element.title }
    string_path.join('/')
  end

  def notify?
    return true if self.notification
    return true if self.dmsf_folder && self.dmsf_folder.notify?
    return true if !self.dmsf_folder && self.project.dmsf_notification
    return false
  end

  def notify_deactivate
    self.notification = nil
    self.save!
  end

  def notify_activate
    self.notification = true
    self.save!
  end

  def self.directory_tree(project, current_folder = nil)
    tree = [[l(:link_documents), nil]]
    project.dmsf_folders.visible.each do |folder|
      unless folder == current_folder
        tree.push(["...#{folder.title}", folder.id])
        directory_subtree(tree, folder, 2, current_folder)
      end
    end
    return tree
  end

  def folder_tree
    tree = [[self.title, self.id]]
    DmsfFolder.directory_subtree(tree, self, 2, nil)
    return tree
  end

  def self.file_list(files)
    options = Array.new
    options.push ['', nil, :label => 'none']
    files.each do |f|
      options.push [f.title, f.id]
    end
    options
  end

  def deep_file_count
    file_count = self.dmsf_files.visible.count
    self.dmsf_folders.visible.each { |subfolder| file_count += subfolder.deep_file_count }
    file_count + self.file_links.visible.count + self.url_links.visible.count
  end

  def deep_folder_count
    folder_count = self.dmsf_folders.visible.count
    self.dmsf_folders.visible.each { |subfolder| folder_count += subfolder.deep_folder_count }
    folder_count + self.folder_links.visible.count
  end

  def deep_size
    size = 0
    self.dmsf_files.visible.each {|file| size += file.size}
    self.dmsf_folders.visible.each {|subfolder| size += subfolder.deep_size}
    size
  end

  # Returns an array of projects that current user can copy folder to
  def self.allowed_target_projects_on_copy
    projects = []
    if User.current.admin?
      projects = Project.visible.has_module('dmsf').all
    elsif User.current.logged?
      User.current.memberships.each do |m|
        projects << m.project if m.project.module_enabled?('dmsf') &&
          m.roles.detect { |r| r.allowed_to?(:folder_manipulation) && r.allowed_to?(:file_manipulation) }
      end
    end
    projects
  end

  def copy_to(project, folder)
    new_folder = DmsfFolder.new
    new_folder.dmsf_folder = folder ? folder : nil
    new_folder.project = folder ? folder.project : project
    new_folder.title = self.title
    new_folder.description = self.description
    new_folder.user = User.current

    new_folder.custom_values = []
    self.custom_values.each do |cv|
      new_folder.custom_values << CustomValue.new({:custom_field => cv.custom_field, :value => cv.value})
    end

    return new_folder unless new_folder.save

    self.dmsf_files.visible.each do |f|
      f.copy_to project, new_folder
    end

    self.dmsf_folders.visible.each do |s|
      s.copy_to project, new_folder
    end

    self.folder_links.visible.each do |l|
      l.copy_to project, new_folder
    end

    self.file_links.visible.each do |l|
      l.copy_to project, new_folder
    end

    self.url_links.visible.each do |l|
      l.copy_to project, new_folder
    end

    return new_folder
  end

  # Overrides Redmine::Acts::Customizable::InstanceMethods#available_custom_fields
  def available_custom_fields
    DmsfFileRevisionCustomField.all
  end

  def modified
    last_update = updated_at
    dmsf_folders.each do |subfolder|
      last_update = subfolder.updated_at if subfolder.updated_at > last_update
    end
    dmsf_files.each do |file|
      last_update = file.updated_at if file.updated_at > last_update
    end
    folder_links.each do |folder_link|
      last_update = folder_link.updated_at if folder_link.updated_at > last_update
    end
    file_links.each do |file_link|
      last_update = file_link.updated_at if file_link.updated_at > last_update
    end
    url_links.each do |url_link|
      last_update = url_link.updated_at if url_link.updated_at > last_update
    end
    last_update
  end

  # Number of items in the folder
  def items
    dmsf_folders.visible.count +
    dmsf_files.visible.count +
    folder_links.visible.count +
    file_links.visible.count +
    url_links.visible.count
  end
  
  def self.is_column_on?(column)
    columns = Setting.plugin_redmine_dmsf['dmsf_columns']
    columns = DmsfFolder::DEFAULT_COLUMNS unless columns
    columns.include? column
  end

  def custom_value(custom_field)
    self.custom_field_values.each do |cv|
      return cv.value if cv.custom_field == custom_field
    end
    nil
  end

  def self.get_column_position(column)
    pos = 0
    columns = Setting.plugin_redmine_dmsf['dmsf_columns']
    columns = DmsfFolder::DEFAULT_COLUMNS unless columns
    # 0 - checkbox
    # 1 - id
    if columns.include?('id')
      pos += 1
      return pos if column == 'id'
    else
      return nil if column == 'id'
    end
    # 2 - title
    if columns.include?('title')
      pos += 1
      return pos if column == 'title'
    else
      return nil if column == 'title'
    end
    # 3 - extension
    if columns.include?('extension')
      pos += 1
      return pos if column == 'extension'
    else
      return nil if column == 'extension'
    end
    # 4 - size
    if columns.include?('size')
      pos += 1
      return pos if column == 'size'
    else
      return nil if column == 'size'
    end
    # 5 - modified
    if columns.include?('modified')
      pos += 1
      return pos if column == 'modified'
    else
      return nil if column == 'modified'
    end
    # 6 - version
    if columns.include?('version')
      pos += 1
      return pos if column == 'version'
    else
      return nil if column == 'version'
    end
    # 7 - workflow
    if columns.include?('workflow')
      pos += 1
      return pos if column == 'workflow'
    else
      return nil if column == 'workflow'
    end
    # 8 - author
    if columns.include?('author')
      pos += 1
      return pos if column == 'author'
    else
      return nil if column == 'author'
    end
    # 9 - custom fields
    cfs = CustomField.where(:type => 'DmsfFileRevisionCustomField')
    cfs.each do |c|
      if DmsfFolder.is_column_on?(c.name)
        pos += 1
      end
    end
    # 10 - commands
    pos += 1
    return pos if column == 'commands'
    # 11 - (position)
    pos += 1
    return pos if column == 'position'
    # 12 - (size)
    pos += 1
    return pos if column == 'size_calculated'
    # 13 - (modified)
    pos += 1
    return pos if column == 'modified_calculated'
    # 14 - (version)
    pos += 1
    return pos if column == 'version_calculated'
    nil
  end

  def save(*args)
    RedmineDmsf::Webdav::Cache.invalidate_item(propfind_cache_key)    
    super(*args)
  end
  
  def save!(*args)
    RedmineDmsf::Webdav::Cache.invalidate_item(propfind_cache_key)    
    super(*args)
  end

  def destroy
    RedmineDmsf::Webdav::Cache.invalidate_item(propfind_cache_key)    
    super
  end

  def destroy!
    RedmineDmsf::Webdav::Cache.invalidate_item(propfind_cache_key)    
    super
  end
  
  def propfind_cache_key
    if dmsf_folder_id.nil?
      # Folder is in project root
      return "PROPFIND/#{project_id}"
    else
      return "PROPFIND/#{project_id}/#{dmsf_folder_id}"
    end
  end

  include ActionView::Helpers::NumberHelper
  include Rails.application.routes.url_helpers

  def to_csv(columns, level)
    csv = []
    # Project
    csv << self.project.name if columns.include?(l(:field_project))
    # Id
    csv << self.id if columns.include?('id')
    # Title
    csv << self.title.insert(0, '  ' * level) if columns.include?('title')
    # Extension
    csv << '' if columns.include?('extension')
    # Size
    csv << '' if columns.include?('size')
    # Modified
    csv << format_time(self.updated_at) if columns.include?('modified')
    # Version
    csv << '' if columns.include?('version')
    # Workflow
    csv << '' if columns.include?('workflow')
    # Author
    csv << self.user.name if columns.include?('author')
    # Url
    if columns.include?(l(:label_document_url))
      default_url_options[:host] = Setting.host_name
      csv << url_for(:controller => :dmsf, :action => 'show', :id => self.project_id, :folder_id => self.id)
    end
    # Revision
    csv << '' if columns.include?(l(:label_last_revision_id))
    # Custom fields
    cfs = CustomField.where(:type => 'DmsfFileRevisionCustomField').order(:position)
    cfs.each do |c|
      csv << self.custom_value(c) if columns.include?(c.name)
    end
    csv
  end

  private

  def self.directory_subtree(tree, folder, level, current_folder)
    folder.dmsf_folders.visible.each do |subfolder|
      unless subfolder == current_folder
        tree.push(["#{'...' * level}#{subfolder.title}", subfolder.id])
        directory_subtree(tree, subfolder, level + 1, current_folder)
      end
    end
  end

end
