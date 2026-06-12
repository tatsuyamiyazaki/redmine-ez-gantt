class EasyGanttController < ApplicationController
  MAX_DEPENDENCY_PATH_DEPTH = 100
  MAX_CASCADE_ISSUES = 200
  MAX_ISSUES = 1_000

  class DependencyGraphTooDeep < StandardError; end
  class CascadeLimitExceeded < StandardError; end
  class IssueLimitExceeded < StandardError; end

  before_action :find_project_by_project_id
  before_action :authorize, only: [:index, :issues, :relations, :create_relation, :delete_relation]
  # update_issue / update_issue_parent はプロジェクトをまたぐチケット編集に対応するため、
  # @project への authorize ではなくチケット側プロジェクトに対する authorize_issue_update で認可する。
  before_action :find_visible_issue, only: [:update_issue, :update_issue_parent]
  before_action :authorize_issue_update, only: [:update_issue, :update_issue_parent]

  def index
    issue_status_and_tracker_ids = visible_project_issues.distinct.pluck(:status_id, :tracker_id)
    status_ids = issue_status_and_tracker_ids.map(&:first).compact.uniq
    tracker_ids = issue_status_and_tracker_ids.map(&:second).compact.uniq

    @easy_gantt_statuses = IssueStatus.where(id: status_ids).order(:position)
    @easy_gantt_trackers = Tracker.where(id: tracker_ids).order(:position)
  end

  def issues
    issues = limited_issues_for_gantt
    editable_by_project_id = editable_by_project_id_for(issues)

    render json: issues.map { |issue|
      EasyGanttIssuePresenter.new(
        issue,
        editable: editable_by_project_id[issue.project_id] && issue.attributes_editable?(User.current)
      ).as_json
    }
  rescue IssueLimitExceeded
    render json: {
      success: false,
      errors: ["Too many issues to display. Limit is #{MAX_ISSUES}."]
    }, status: :unprocessable_entity
  end

  def relations
    issue_ids = visible_project_issues.select(:id)

    rels = IssueRelation.where(
      relation_type: IssueRelation::TYPE_PRECEDES,
      issue_from_id: issue_ids,
      issue_to_id: issue_ids
    )

    render json: rels.map { |r|
      { id: r.id, from_id: r.issue_from_id, to_id: r.issue_to_id, delay: r.delay.to_i }
    }
  end

  def update_issue
    attributes = issue_params
    unsafe_attributes = unsafe_issue_attributes(@issue, attributes)

    if unsafe_attributes.any?
      render json: { success: false, errors: ['Not authorized'] }, status: :forbidden
      return
    end

    parsed_dates = parse_issue_dates(attributes)
    return unless parsed_dates

    start_date = attributes.key?('start_date') ? parsed_dates[:start_date] : @issue.start_date
    due_date = attributes.key?('due_date') ? parsed_dates[:due_date] : @issue.due_date

    if start_date && due_date && start_date > due_date
      render json: { success: false, errors: ['start_date must be on or before due_date'] }, status: :unprocessable_entity
      return
    end

    if attributes.key?('done_ratio')
      done_ratio = parse_done_ratio(attributes['done_ratio'])

      unless done_ratio
        render json: { success: false, errors: ['done_ratio must be an integer between 0 and 100'] }, status: :unprocessable_entity
        return
      end
    end

    @issue.init_journal(User.current)
    @issue.safe_attributes = attributes

    affected = []
    saved = save_issue_with_cascade(@issue, affected)
    return if performed?

    if saved
      render json: {
        success: true,
        issue: EasyGanttIssuePresenter.new(@issue, editable: editable_issue?(@issue)).as_json,
        affected_issues: affected.map { |i| EasyGanttIssuePresenter.new(i, editable: editable_issue?(i)).as_json }
      }
    else
      render json: { success: false, errors: @issue.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update_issue_parent
    attributes = parent_issue_params

    if unsafe_issue_attributes(@issue, attributes).any?
      render json: { success: false, errors: ['Not authorized'] }, status: :forbidden
      return
    end

    parent_issue = find_parent_issue(attributes['parent_issue_id'])

    if parent_issue && !editable_issue?(parent_issue)
      render json: { success: false, errors: ['Not authorized'] }, status: :forbidden
      return
    end

    if invalid_parent_issue?(parent_issue)
      render json: { success: false, errors: ['invalid parent issue'] }, status: :unprocessable_entity
      return
    end

    @issue.init_journal(User.current)
    @issue.safe_attributes = attributes

    if @issue.save
      render json: { success: true, issue: EasyGanttIssuePresenter.new(@issue, editable: editable_issue?(@issue)).as_json }
    else
      render json: { success: false, errors: @issue.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def create_relation
    from_issue = visible_project_issues.find(params[:from_id])
    to_issue   = visible_project_issues.find(params[:to_id])

    unless editable_relation_issue?(from_issue) && editable_relation_issue?(to_issue)
      render json: { success: false, errors: ['Not authorized'] }, status: :forbidden
      return
    end

    if from_issue.id == to_issue.id
      render json: { success: false, errors: ['An issue cannot depend on itself'] }, status: :unprocessable_entity
      return
    end

    begin
      circular_dependency = dependency_path_exists?(to_issue.id, from_issue.id)
    rescue DependencyGraphTooDeep
      render json: { success: false, errors: ['Dependency graph is too deep'] }, status: :unprocessable_entity
      return
    end

    if circular_dependency
      render json: { success: false, errors: ['This relation would create a circular dependency'] }, status: :unprocessable_entity
      return
    end

    relation = IssueRelation.new
    relation.issue_from = from_issue
    relation.safe_attributes = {
      'relation_type' => IssueRelation::TYPE_PRECEDES,
      'issue_to_id' => to_issue.id,
      'delay' => 0
    }
    relation.init_journals(User.current)

    affected = []

    begin
      saved = IssueRelation.transaction do
        relation.save.tap do |relation_saved|
          affected.concat(cascade_successors(from_issue)) if relation_saved
        end
      end
    rescue CascadeLimitExceeded
      render json: { success: false, errors: ['Too many dependent issues to update'] }, status: :unprocessable_entity
      return
    end

    if saved
      render json: {
        success: true,
        relation: { id: relation.id, from_id: relation.issue_from_id, to_id: relation.issue_to_id, delay: relation.delay.to_i },
        affected_issues: affected.map { |i| EasyGanttIssuePresenter.new(i, editable: editable_issue?(i)).as_json }
      }
    else
      render json: { success: false, errors: relation.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def delete_relation
    issue_ids = visible_project_issues.select(:id)
    relation = IssueRelation.where(
      id: params[:id],
      relation_type: IssueRelation::TYPE_PRECEDES,
      issue_from_id: issue_ids,
      issue_to_id: issue_ids
    ).includes(:issue_from, :issue_to).first

    if relation.nil?
      render json: { success: false, errors: ['Not found'] }, status: :not_found
      return
    end

    unless editable_relation_issue?(relation.issue_from) && editable_relation_issue?(relation.issue_to) && relation.deletable?
      render json: { success: false, errors: ['Not authorized'] }, status: :forbidden
      return
    end

    relation.init_journals(User.current)
    relation.destroy
    render json: { success: true }
  end

  private

  def find_visible_issue
    @issue = visible_project_issues.includes(:status, :assigned_to, :tracker, :parent, :project).find(params[:id])
  end

  def visible_project_issues
    Issue.visible.where(project_id: visible_easy_gantt_project_ids)
  end

  def authorize_issue_update
    render_403 unless editable_issue?(@issue)
  end

  def issue_params
    params.require(:issue).permit(:start_date, :due_date, :done_ratio).to_h
  end

  def parent_issue_params
    params.require(:issue).permit(:parent_issue_id).to_h
  end

  def find_parent_issue(parent_issue_id)
    return nil if parent_issue_id.blank?

    visible_project_issues.find(parent_issue_id)
  end

  def invalid_parent_issue?(parent_issue)
    return false unless parent_issue
    return true if parent_issue.id == @issue.id

    issue_ids_from_parent_to_root(parent_issue).include?(@issue.id)
  end

  def issue_ids_from_parent_to_root(issue)
    ids = []
    current = issue

    while current && !ids.include?(current.id)
      ids << current.id
      current = current.parent
    end

    ids
  end

  def editable_issue?(issue)
    issue &&
      issue.visible?(User.current) &&
      issue.project.module_enabled?(:easy_gantt) &&
      User.current.allowed_to?(:view_easy_gantt, issue.project) &&
      User.current.allowed_to?(:edit_easy_gantt, issue.project) &&
      issue.attributes_editable?(User.current)
  end

  def editable_relation_issue?(issue)
    issue &&
      issue.visible?(User.current) &&
      issue.project.module_enabled?(:easy_gantt) &&
      User.current.allowed_to?(:view_easy_gantt, issue.project) &&
      User.current.allowed_to?(:edit_easy_gantt, issue.project) &&
      User.current.allowed_to?(:manage_issue_relations, issue.project)
  end

  def visible_easy_gantt_project_ids
    @visible_easy_gantt_project_ids ||= Project
      .where(Project.allowed_to_condition(User.current, :view_easy_gantt, project: @project, with_subprojects: true))
      .pluck(:id)
  end

  def unsafe_issue_attributes(issue, attributes)
    attributes.keys.map(&:to_s) - issue.safe_attribute_names(User.current)
  end

  def editable_by_project_id_for(issues)
    issues.map(&:project).uniq.index_with do |project|
      project.module_enabled?(:easy_gantt) &&
        User.current.allowed_to?(:view_easy_gantt, project) &&
        User.current.allowed_to?(:edit_easy_gantt, project)
    end.transform_keys(&:id)
  end

  def limited_issues_for_gantt
    issues = visible_project_issues
               .includes(:status, :assigned_to, :tracker, :parent, :project)
               .references(:project)
               .order('projects.lft, issues.start_date, issues.id')
               .limit(MAX_ISSUES + 1)
               .to_a

    raise IssueLimitExceeded if issues.size > MAX_ISSUES

    issues
  end

  def save_issue_with_cascade(issue, affected)
    Issue.transaction do
      saved = issue.save
      affected.concat(cascade_successors(issue)) if saved
      saved
    end
  rescue CascadeLimitExceeded
    render json: { success: false, errors: ['Too many dependent issues to update'] }, status: :unprocessable_entity
    nil
  end

  def parse_issue_dates(attributes)
    dates = {}

    %w[start_date due_date].each do |attribute|
      next unless attributes.key?(attribute)

      dates[attribute.to_sym] = parse_date(attributes[attribute])
    rescue ArgumentError
      render json: { success: false, errors: ["#{attribute} must be a valid ISO 8601 date"] }, status: :unprocessable_entity
      return nil
    end

    dates
  end

  def dependency_path_exists?(from_issue_id, to_issue_id, issue_ids = visible_project_issues.select(:id))
    visited = Set.new
    frontier = [from_issue_id]

    until frontier.empty?
      return true if frontier.include?(to_issue_id)

      frontier.each { |issue_id| visited.add(issue_id) }
      raise DependencyGraphTooDeep if visited.size >= MAX_DEPENDENCY_PATH_DEPTH

      frontier = IssueRelation.where(
        issue_from_id: frontier,
        issue_to_id: issue_ids,
        relation_type: IssueRelation::TYPE_PRECEDES
      ).distinct.pluck(:issue_to_id).reject { |issue_id| visited.include?(issue_id) }
    end

    false
  end

  def cascade_successors(issue, visited = Set.new)
    raise CascadeLimitExceeded if visited.size >= MAX_CASCADE_ISSUES

    visited.add(issue.id)
    affected = []
    frontier = [issue]

    until frontier.empty?
      relation_rows = IssueRelation.where(
        issue_from_id: frontier.map(&:id),
        relation_type: IssueRelation::TYPE_PRECEDES
      ).pluck(:issue_from_id, :issue_to_id, :delay)
      break if relation_rows.empty?

      successors = visible_project_issues
                     .includes(:status, :assigned_to, :tracker, :parent, :project)
                     .where(id: relation_rows.map { |(_, issue_to_id, _)| issue_to_id }.uniq - visited.to_a)
                     .index_by(&:id)
      relations_by_from_id = relation_rows.group_by { |(issue_from_id, _, _)| issue_from_id }
      next_frontier = []

      frontier.each do |predecessor|
        Array(relations_by_from_id[predecessor.id]).each do |(_, successor_id, delay)|
          successor = successors[successor_id]
          next unless editable_issue?(successor)
          next unless successor.start_date && successor.due_date && predecessor.due_date

          min_start = predecessor.due_date + delay.to_i + 1
          next if successor.start_date >= min_start
          raise CascadeLimitExceeded if affected.size >= MAX_CASCADE_ISSUES

          duration = (successor.due_date - successor.start_date).to_i
          successor.init_journal(User.current)
          successor.start_date = min_start
          successor.due_date = min_start + duration
          next unless successor.save

          visited.add(successor.id)
          affected << successor
          next_frontier << successor
        end
      end

      frontier = next_frontier
    end

    affected
  end

  def parse_date(value)
    return nil if value.blank?

    Date.iso8601(value)
  end

  def parse_done_ratio(value)
    return nil unless value.to_s.match?(/\A\d+\z/)

    ratio = value.to_s.to_i
    return nil unless ratio.between?(0, 100)

    ratio
  end
end
