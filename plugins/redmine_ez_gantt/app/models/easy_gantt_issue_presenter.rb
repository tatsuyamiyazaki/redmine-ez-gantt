class EasyGanttIssuePresenter
  def initialize(issue, editable: nil)
    @issue = issue
    @editable = editable
  end

  def as_json(*)
    {
      id: issue.id,
      subject: issue.subject,
      tracker: named_entity(issue.tracker),
      status: named_entity(issue.status),
      assigned_to: named_entity(issue.assigned_to),
      project: named_entity(issue.project),
      project_id: issue.project_id,
      parent_issue_id: issue.parent_id,
      start_date: formatted_date(issue.start_date),
      due_date: formatted_date(issue.due_date),
      done_ratio: issue.done_ratio,
      editable: editable?
    }
  end

  private

  attr_reader :issue

  def named_entity(record)
    return nil unless record

    {
      id: record.id,
      name: record.name
    }
  end

  def formatted_date(date)
    date&.iso8601
  end

  # フォールバックは EasyGanttController#editable_issue? と同じ条件を保つこと。
  # 呼び出し側が判定済みの場合は editable: で明示的に渡すのが基本。
  def editable?
    return @editable unless @editable.nil?

    issue.visible?(User.current) &&
      issue.project.module_enabled?(:easy_gantt) &&
      User.current.allowed_to?(:view_easy_gantt, issue.project) &&
      User.current.allowed_to?(:edit_easy_gantt, issue.project) &&
      issue.attributes_editable?(User.current)
  end
end
