class EasyGanttController < ApplicationController
  before_action :find_project_by_project_id, only: [:index, :issues]
  before_action :authorize, only: [:index, :issues]
  before_action :find_visible_issue, only: [:update_issue, :update_issue_parent]
  before_action :authorize_issue_update, only: [:update_issue, :update_issue_parent]

  def index
  end

  def issues
    issues = Issue.visible
                  .where(project_id: @project.self_and_descendants.select(:id))
                  .includes(:status, :assigned_to, :tracker, :parent)
                  .order(:start_date, :id)

    render json: issues.map { |issue| EasyGanttIssuePresenter.new(issue).as_json }
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
      render json: { success: true, issue: EasyGanttIssuePresenter.new(@issue).as_json }
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

  private

  def find_visible_issue
    @issue = Issue.visible.includes(:status, :assigned_to, :tracker, :parent).find(params[:id])
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
