class EasyGanttController < ApplicationController
  before_action :find_project_by_project_id, only: [:index, :issues, :relations]
  before_action :authorize, only: [:index, :issues, :relations]
  before_action :find_visible_issue, only: [:update_issue, :update_issue_parent]
  before_action :authorize_issue_update, only: [:update_issue, :update_issue_parent]

  def index
  end

  def issues
    issues = Issue.visible
                  .where(project_id: @project.self_and_descendants.select(:id))
                  .includes(:status, :assigned_to, :tracker, :parent, :project)
                  .references(:project)
                  .order('projects.lft, issues.start_date, issues.id')

    render json: issues.map { |issue| EasyGanttIssuePresenter.new(issue).as_json }
  end

  def relations
    issue_ids = Issue.visible
                     .where(project_id: @project.self_and_descendants.select(:id))
                     .select(:id)

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
    start_date = attributes.key?(:start_date) ? parse_date(attributes[:start_date]) : @issue.start_date
    due_date = attributes.key?(:due_date) ? parse_date(attributes[:due_date]) : @issue.due_date

    if start_date && due_date && start_date > due_date
      render json: { success: false, errors: ['start_date must be on or before due_date'] }, status: :unprocessable_entity
      return
    end

    if attributes.key?(:done_ratio)
      done_ratio = parse_done_ratio(attributes[:done_ratio])

      unless done_ratio
        render json: { success: false, errors: ['done_ratio must be an integer between 0 and 100'] }, status: :unprocessable_entity
        return
      end

      @issue.done_ratio = done_ratio
    end

    @issue.start_date = start_date if attributes.key?(:start_date)
    @issue.due_date = due_date if attributes.key?(:due_date)

    if @issue.save
      affected = cascade_successors(@issue)
      render json: {
        success: true,
        issue: EasyGanttIssuePresenter.new(@issue).as_json,
        affected_issues: affected.map { |i| EasyGanttIssuePresenter.new(i).as_json }
      }
    else
      render json: { success: false, errors: @issue.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update_issue_parent
    parent_issue = find_parent_issue(parent_issue_params[:parent_issue_id])

    if invalid_parent_issue?(parent_issue)
      render json: { success: false, errors: ['invalid parent issue'] }, status: :unprocessable_entity
      return
    end

    @issue.parent_id = parent_issue&.id

    if @issue.save
      render json: { success: true, issue: EasyGanttIssuePresenter.new(@issue).as_json }
    else
      render json: { success: false, errors: @issue.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def create_relation
    from_issue = Issue.visible.find(params[:from_id])
    to_issue   = Issue.visible.find(params[:to_id])

    unless User.current.allowed_to?(:edit_easy_gantt, from_issue.project)
      render json: { success: false, errors: ['Not authorized'] }, status: :forbidden
      return
    end

    if from_issue.id == to_issue.id
      render json: { success: false, errors: ['An issue cannot depend on itself'] }, status: :unprocessable_entity
      return
    end

    relation = IssueRelation.new(
      issue_from_id: from_issue.id,
      issue_to_id: to_issue.id,
      relation_type: IssueRelation::TYPE_PRECEDES,
      delay: 0
    )

    if relation.save
      affected = cascade_successors(from_issue)
      render json: {
        success: true,
        relation: { id: relation.id, from_id: relation.issue_from_id, to_id: relation.issue_to_id, delay: relation.delay.to_i },
        affected_issues: affected.map { |i| EasyGanttIssuePresenter.new(i).as_json }
      }
    else
      render json: { success: false, errors: relation.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def delete_relation
    issue_ids = Issue.visible.select(:id)
    relation = IssueRelation.where(
      id: params[:id],
      relation_type: IssueRelation::TYPE_PRECEDES,
      issue_from_id: issue_ids
    ).includes(:issue_from).first

    if relation.nil?
      render json: { success: false, errors: ['Not found'] }, status: :not_found
      return
    end

    unless User.current.allowed_to?(:edit_easy_gantt, relation.issue_from.project)
      render json: { success: false, errors: ['Not authorized'] }, status: :forbidden
      return
    end

    relation.destroy
    render json: { success: true }
  end

  private

  def find_visible_issue
    @issue = Issue.visible.includes(:status, :assigned_to, :tracker, :parent, :project).find(params[:id])
  end

  def authorize_issue_update
    render_403 unless User.current.allowed_to?(:edit_easy_gantt, @issue.project)
  end

  def issue_params
    params.require(:issue).permit(:start_date, :due_date, :done_ratio)
  end

  def parent_issue_params
    params.require(:issue).permit(:parent_issue_id)
  end

  def find_parent_issue(parent_issue_id)
    return nil if parent_issue_id.blank?

    Issue.visible.find(parent_issue_id)
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

  def cascade_successors(issue, visited = Set.new)
    return [] if visited.include?(issue.id)
    visited.add(issue.id)

    affected = []

    IssueRelation.where(
      issue_from_id: issue.id,
      relation_type: IssueRelation::TYPE_PRECEDES
    ).includes(:issue_to).each do |relation|
      successor = relation.issue_to
      next unless successor.start_date && successor.due_date && issue.due_date

      delay = relation.delay.to_i
      min_start = issue.due_date + delay + 1
      next if successor.start_date >= min_start

      duration = (successor.due_date - successor.start_date).to_i
      successor.update_columns(start_date: min_start, due_date: min_start + duration)
      affected << successor
      affected.concat(cascade_successors(successor, visited))
    end

    affected
  end

  def parse_date(value)
    return nil if value.blank?

    Date.iso8601(value)
  rescue ArgumentError
    nil
  end

  def parse_done_ratio(value)
    ratio = Integer(value)
    return nil unless ratio.between?(0, 100)

    ratio
  rescue ArgumentError, TypeError
    nil
  end
end
