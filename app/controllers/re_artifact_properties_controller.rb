include WatchersHelper

class ReArtifactPropertiesController < RedmineReController
  unloadable
  menu_item :re

  helper :watchers

  def show
    render :text => "not implemented"
  end

  def new
    @re_artifact_properties = ReArtifactProperties.new
    @re_artifact_properties.artifact_type = params[:artifact_type].camelcase
    @artifact_type = params[:artifact_type]

    @re_artifact_properties.project = @project

    @bb_hash = ReBuildingBlock.find_all_bbs_and_data(@re_artifact_properties, @project.id)

    unless params[:parent_artifact_id].blank?
      parent = ReArtifactProperties.find(params[:parent_artifact_id])
      @parent_artifact_id = parent.id
      begin
        @parent_relation_position = parent.child_relations.last.position + 1
      rescue NoMethodError # child_relations.last = nil -> creating the first artifact
        @parent_relation_position = 1
      end
    end

    unless params[:sibling_artifact_id].blank?
      sibling = ReArtifactProperties.find(params[:sibling_artifact_id])
      @parent_artifact_id = sibling.parent.id
      @parent_relation_position = sibling.parent_relation.position + 1
    end
  end

  def create
    @re_artifact_properties = ReArtifactProperties.new
    @re_artifact_properties.attributes = params[:re_artifact_properties]
    @artifact_type = @re_artifact_properties.artifact_type

    @bb_hash = ReBuildingBlock.find_all_bbs_and_data(@re_artifact_properties, @project.id)
    @bb_error_hash = {}
    @bb_error_hash = ReBuildingBlock.validate_building_blocks(@re_artifact_properties, @bb_error_hash, @project.id)

    @issues = @re_artifact_properties.issues

    # attributes that cannot be set by the user
    # @re_artifact_properties.project_id = @project.id
    @re_artifact_properties.created_at = Time.now
    @re_artifact_properties.updated_at = Time.now
    @re_artifact_properties.created_by = User.current.id
    @re_artifact_properties.updated_by = User.current.id

    # relation related attributes
    unless params[:parent_artifact_id].blank? || params[:parent_relation_position].blank?
      @re_artifact_properties.parent = ReArtifactProperties.find(params[:parent_artifact_id])
      logger.debug("ReArtifactProperties.create => parent_relation: #{@re_artifact_properties.parent_relation.inspect}") if logger
      @parent_artifact_id = params[:parent_artifact_id]
      @parent_relation_position = params[:parent_relation_position]
    end

    if @re_artifact_properties.save
      @re_artifact_properties.parent_relation.insert_at(params[:parent_relation_position])
      render :edit
    else
      logger.debug("ReArtifactProperties.create => Errors: #{@re_artifact_properties.errors.inspect}") if logger
      render :new
    end
  end

  def edit
    @re_artifact_properties = ReArtifactProperties.find(params[:id])
    @artifact_type = @re_artifact_properties.artifact_type
    @bb_hash = ReBuildingBlock.find_all_bbs_and_data(@re_artifact_properties, @project.id)
  end

  def update
    @re_artifact_properties = ReArtifactProperties.find(params[:id])
    @bb_hash = ReBuildingBlock.find_all_bbs_and_data(@re_artifact_properties, @project.id)
    @bb_error_hash = {}
    @bb_error_hash = ReBuildingBlock.validate_building_blocks(@re_artifact_properties, @bb_error_hash, @project.id)

    @issues = @re_artifact_properties.issues

    @re_artifact_properties.attributes = params[:re_artifact_properties]
    # attributes that cannot be set by the user
    @re_artifact_properties.updated_at = Time.now
    @re_artifact_properties.updated_by = User.current.id

    @re_artifact_properties.save
    render :edit
  end

  def delete
    method = params[:mode]
    @artifact_properties = ReArtifactProperties.find(params[:id])

    @relationships_incoming = @artifact_properties.relationships_as_sink
    @relationships_outgoing = @artifact_properties.relationships_as_source
    @parent = @artifact_properties.parent

    @children = gather_children(@artifact_properties)

    @relationships_incoming.delete_if {|x| x.relation_type.eql? ReArtifactRelationship::RELATION_TYPES[:pch] }
    @relationships_outgoing.delete_if {|x| x.relation_type.eql? ReArtifactRelationship::RELATION_TYPES[:pch] }

    case method
      when 'move'
        direct_children = @artifact_properties.children
        position = @artifact_properties.position
        for child in direct_children
          logger.debug "################### #{child.to_yaml}" if logger
          child.parent_relation.remove_from_list
          child.parent = @parent
          child.parent_relation.insert_at(position)
          position += 1
        end
        @artifact_properties.destroy

        flash.now[:notice] = t(:re_deleted_artifact_and_moved_children, :artifact => @artifact_properties.name, :parent => @parent.name)
        redirect_to :controller => 'requirements', :action => 'index', :project_id => @project.id

      when 'recursive'
        for child in @children
          child.destroy
        end
        @artifact_properties.destroy

        flash.now[:notice] = t(:re_deleted_artifact_and_children, :artifact => @artifact_properties.name)
        redirect_to :controller => 'requirements', :action => 'index', :project_id => @project.id
      else
        @children = gather_children(@artifact_properties)
    end
  end

  def autocomplete_issue
    query = '%' + params[:issue_subject].gsub('%', '\%').gsub('_', '\_').downcase + '%'
    issues_for_ac = Issue.find(:all, :conditions=>['subject like ? AND project_id=?', query , @project.id])
    list = '<ul>'
    issues_for_ac.each do |issue|
      list << '<li ' + 'id='+issue.id.to_s+'>'
      list << issue.subject.to_s+' ('+issue.id.to_s+')'
      list << '</li>'
    end

    list << '</ul>'
    render :text => list
  end

  def remove_issue_from_artifact
    issue_to_delete = Issue.find(params[:issueid])
    artifact_type = self.controller_name
    artifact_properties = artifact_type.camelcase.constantize.find_by_id(params[:id])
    artifact_properties.issues.delete(issue_to_delete)
    redirect_to(:back)
  end

  def autocomplete_artifact
    query = '%' + params[:artifact_name].gsub('%', '\%').gsub('_', '\_').downcase + '%'
    issues_for_ac = ReArtifactProperties.find(:all, :conditions=>['name like ? AND project_id = ?', query, @project.id])
    list = '<ul>'
    issues_for_ac.each do |aprop|
      list << '<li ' + 'id='+aprop.id.to_s+'>'
      list << aprop.name.to_s+' ('+aprop.id.to_s+')'
      list << '</li>'
    end

    list << '</ul>'
    render :text => list
  end

  def remove_artifact_from_issue
    artifact_to_delete = ReArtifactProperties.find(params[:artifactid])
    issue = Issue.find(params[:issueid])
    issue.re_artifact_properties.delete(artifact_to_delete)
    redirect_to(:back)
  end

  # Ajax call
  def autocomplete_parent
    artifact = ReArtifactProperties.find(params[:id]) unless params[:id].blank?

    query = '%' + params[:parent_name].gsub('%', '\%').gsub('_', '\_').downcase + '%'
    parents = ReArtifactProperties.find(:all, :conditions => ['name like ?', query ])

    if artifact
      children = artifact.gather_children
      parents.delete_if{ |p| children.include? p }
      parents.delete_if{ |p| p == artifact }
    end

    list = '<ul>'
    for parent in parents
      list << render_autocomplete_artifact_list_entry(parent)
    end
    list << '</ul>'
    render :text => list
  end

  def rate_artifact
     @artifact = ReArtifactProperties.find(params[:id])
     @artifact.rate(params[:stars], User.current, params[:dimension])
     render :update do |page|
       page.replace_html :rating, render(:partial => '/re_artifact_properties/rating', :locals => {:artifact => @artifact})
       page.visual_effect :pulsate, @artifact.wrapper_dom_id(params)
     end
  end

  private

  def gather_children(artifact)
    # recursively gathers all children for the given artifact
    #
    children = Array.new
    children.concat artifact.children
    return children if artifact.changed? || artifact.children.empty?
    for child in children
      children.concat gather_children(child)
    end
    children
  end

end
