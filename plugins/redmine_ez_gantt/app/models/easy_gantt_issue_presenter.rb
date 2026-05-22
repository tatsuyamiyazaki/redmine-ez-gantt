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

  def editable?
    return @editable unless @editable.nil?

    User.current.allowed_to?(:edit_easy_gantt, issue.project)
  end
end
