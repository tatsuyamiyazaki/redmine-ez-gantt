root_project = Project.find_or_initialize_by(identifier: 'easy-gantt-test')
root_project.name = 'Easy Gantt Test'
root_project.description = 'Root project for redmine_ez_gantt test data.'
root_project.is_public = false
root_project.status = Project::STATUS_ACTIVE if defined?(Project::STATUS_ACTIVE)
root_project.save!

statuses = {
  '新規' => false,
  '進行中' => false,
  '完了' => true
}.each_with_object({}) do |(name, closed), memo|
  status = IssueStatus.find_or_initialize_by(name: name)
  status.is_closed = closed
  status.position ||= IssueStatus.maximum(:position).to_i + 1
  status.save!
  memo[name] = status
end

tracker = Tracker.find_or_initialize_by(name: 'タスク')
tracker.default_status = statuses['新規'] if tracker.respond_to?(:default_status=)
tracker.position ||= Tracker.maximum(:position).to_i + 1
tracker.save!
tracker.issue_statuses = statuses.values if tracker.respond_to?(:issue_statuses=)
tracker.save!

role = Role.find_or_initialize_by(name: 'Easy Gantt Manager')
role.assignable = true if role.respond_to?(:assignable=)
role.permissions = %i[
  view_project
  view_issues
  add_issues
  edit_issues
  view_easy_gantt
  edit_easy_gantt
]
role.save!

users = %w[pm dev1 dev2 reviewer].each_with_object({}) do |login, memo|
  user = User.find_or_initialize_by(login: login)
  user.firstname = login
  user.lastname = 'User'
  user.mail = "#{login}@example.test"
  user.language = 'ja' if user.respond_to?(:language=)
  user.status = Principal::STATUS_ACTIVE
  user.password = 'password'
  user.password_confirmation = 'password' if user.respond_to?(:password_confirmation=)
  user.save!
  memo[login] = user
end

subproject_definitions = [
  { identifier: 'easy-gantt-plan', name: '計画フェーズ', start_date: '2026-05-01' },
  { identifier: 'easy-gantt-dev',  name: '開発フェーズ', start_date: '2026-06-01' },
  { identifier: 'easy-gantt-ops',  name: '運用フェーズ', start_date: '2026-07-01' }
]

subprojects = subproject_definitions.map do |info|
  sp = Project.find_or_initialize_by(identifier: info[:identifier])
  sp.name = info[:name]
  sp.description = "Sub project (#{info[:name]}) for redmine_ez_gantt test data."
  sp.is_public = false
  sp.status = Project::STATUS_ACTIVE if defined?(Project::STATUS_ACTIVE)
  sp.save!

  if sp.parent_id != root_project.id
    if sp.respond_to?(:set_parent!)
      sp.set_parent!(root_project)
    else
      sp.parent = root_project
      sp.save!
    end
  end

  { project: sp.reload, start_date: Date.iso8601(info[:start_date]) }
end

[root_project, *subprojects.map { |sp| sp[:project] }].each do |project|
  project.trackers = (project.trackers + [tracker]).uniq
  project.enabled_module_names = (project.enabled_module_names + %w[issue_tracking easy_gantt]).uniq
  project.save!

  users.each_value do |user|
    Member.find_or_create_by!(project: project, user: user) do |member|
      member.roles = [role]
    end.tap do |member|
      member.roles = [role] unless member.roles.include?(role)
      member.save!
    end
  end
end

all_project_ids = [root_project.id, *subprojects.map { |sp| sp[:project].id }]
existing_issue_ids = Issue.where(project_id: all_project_ids).pluck(:id)
if existing_issue_ids.any?
  IssueRelation.where(issue_from_id: existing_issue_ids)
               .or(IssueRelation.where(issue_to_id: existing_issue_ids))
               .delete_all
end

priority =
  IssuePriority.default ||
  IssuePriority.first ||
  IssuePriority.create!(name: '通常', position: 1, is_default: true, active: true)

def seed_issue(project:, tracker:, status:, priority:, author:, assigned_to:, subject:, start_date:, due_date:, parent: nil, done_ratio: 0)
  issue = Issue.where(project: project, subject: subject).first_or_initialize
  issue.tracker = tracker
  issue.status = status
  issue.priority = priority
  issue.author = author
  issue.assigned_to = assigned_to
  issue.start_date = Date.iso8601(start_date)
  issue.due_date = Date.iso8601(due_date)
  issue.done_ratio = done_ratio
  issue.parent_issue_id = parent&.id
  issue.notify = false if issue.respond_to?(:notify=)
  issue.send_notification = false if issue.respond_to?(:send_notification=)
  issue.save!(validate: false)
  issue
end

assignees = [users['pm'], users['dev1'], users['dev2'], users['reviewer']]
status_names = %w[新規 進行中 完了]
parent_status_names = %w[新規 進行中]
groups_per_subproject = 10
children_per_group = 9

subprojects.each do |sp|
  project = sp[:project]
  base_start_date = sp[:start_date]

  (1..groups_per_subproject).each do |group_index|
    group_start_date = base_start_date + (group_index - 1) * 7
    parent_status_name = parent_status_names[group_index % parent_status_names.size]
    parent_done_ratio = parent_status_name == '進行中' ? (group_index * 10) % 90 : 0

    parent_issue = seed_issue(
      project: project,
      tracker: tracker,
      status: statuses[parent_status_name],
      priority: priority,
      author: users['pm'],
      assigned_to: assignees[group_index % assignees.size],
      subject: format('%s 親-%02d', project.name, group_index),
      start_date: group_start_date.iso8601,
      due_date: (group_start_date + 9).iso8601,
      done_ratio: parent_done_ratio
    )

    (1..children_per_group).each do |item_index|
      child_start_date = group_start_date + item_index - 1
      child_status_name = status_names[(group_index + item_index) % status_names.size]
      child_done_ratio =
        case child_status_name
        when '完了' then 100
        when '進行中' then (item_index * 10) % 100
        else 0
        end

      seed_issue(
        project: project,
        tracker: tracker,
        status: statuses[child_status_name],
        priority: priority,
        author: users['pm'],
        assigned_to: assignees[(group_index + item_index) % assignees.size],
        subject: format('%s 子-%02d-%02d', project.name, group_index, item_index),
        start_date: child_start_date.iso8601,
        due_date: (child_start_date + 2).iso8601,
        parent: parent_issue,
        done_ratio: child_done_ratio
      )
    end
  end
end

puts 'Easy Gantt seed data is ready.'
