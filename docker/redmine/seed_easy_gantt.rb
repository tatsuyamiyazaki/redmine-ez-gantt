project = Project.find_or_initialize_by(identifier: 'easy-gantt-test')
project.name = 'Easy Gantt Test'
project.description = 'Test project for redmine_easy_gantt.'
project.is_public = false
project.status = Project::STATUS_ACTIVE if defined?(Project::STATUS_ACTIVE)
project.save!

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

project.trackers = (project.trackers + [tracker]).uniq
project.enabled_module_names = (project.enabled_module_names + %w[issue_tracking easy_gantt]).uniq
project.save!

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

  Member.find_or_create_by!(project: project, user: user) do |member|
    member.roles = [role]
  end.tap do |member|
    member.roles = [role] unless member.roles.include?(role)
    member.save!
  end

  memo[login] = user
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
  issue.save!
  issue
end

parents = {}
parents['要件定義'] = seed_issue(
  project: project,
  tracker: tracker,
  status: statuses['進行中'],
  priority: priority,
  author: users['pm'],
  assigned_to: users['pm'],
  subject: '要件定義',
  start_date: '2026-05-01',
  due_date: '2026-05-07',
  done_ratio: 40
)
parents['設計'] = seed_issue(
  project: project,
  tracker: tracker,
  status: statuses['新規'],
  priority: priority,
  author: users['pm'],
  assigned_to: users['dev1'],
  subject: '設計',
  start_date: '2026-05-08',
  due_date: '2026-05-14',
  done_ratio: 10
)
parents['実装'] = seed_issue(
  project: project,
  tracker: tracker,
  status: statuses['新規'],
  priority: priority,
  author: users['pm'],
  assigned_to: users['dev1'],
  subject: '実装',
  start_date: '2026-05-15',
  due_date: '2026-05-28',
  done_ratio: 0
)
parents['テスト'] = seed_issue(
  project: project,
  tracker: tracker,
  status: statuses['新規'],
  priority: priority,
  author: users['pm'],
  assigned_to: users['reviewer'],
  subject: 'テスト',
  start_date: '2026-05-29',
  due_date: '2026-06-05',
  done_ratio: 0
)

children = [
  ['現行業務ヒアリング', '要件定義', 'pm', '2026-05-01', '2026-05-03', '完了', 100],
  ['要件整理', '要件定義', 'pm', '2026-05-04', '2026-05-07', '進行中', 40],
  ['画面設計', '設計', 'dev1', '2026-05-08', '2026-05-10', '新規', 0],
  ['DB設計', '設計', 'dev2', '2026-05-11', '2026-05-14', '新規', 0],
  ['ガントチャート表示機能', '実装', 'dev1', '2026-05-15', '2026-05-19', '新規', 0],
  ['バー移動・リサイズ機能', '実装', 'dev1', '2026-05-20', '2026-05-23', '新規', 0],
  ['親子関係変更機能', '実装', 'dev2', '2026-05-24', '2026-05-28', '新規', 0],
  ['結合テスト', 'テスト', 'reviewer', '2026-05-29', '2026-06-02', '新規', 0],
  ['操作テスト', 'テスト', 'reviewer', '2026-06-03', '2026-06-05', '新規', 0]
]

children.each do |subject, parent_subject, assigned_to, start_date, due_date, status_name, done_ratio|
  seed_issue(
    project: project,
    tracker: tracker,
    status: statuses[status_name],
    priority: priority,
    author: users['pm'],
    assigned_to: users[assigned_to],
    subject: subject,
    start_date: start_date,
    due_date: due_date,
    parent: parents[parent_subject],
    done_ratio: done_ratio
  )
end

base_issue_count = parents.size + children.size
target_issue_count = 500
generated_issue_count = [target_issue_count - base_issue_count, 0].max
generated_parent = nil
assignees = [users['pm'], users['dev1'], users['dev2'], users['reviewer']]
status_names = %w[新規 進行中 完了]
parent_status_names = %w[新規 進行中]
load_start_date = Date.iso8601('2026-06-08')

(1..generated_issue_count).each do |index|
  group_index = ((index - 1) / 10) + 1
  item_index = (index - 1) % 10
  group_start_date = load_start_date + ((group_index - 1) * 7)
  assigned_to = assignees[index % assignees.size]

  if item_index.zero?
    status_name = parent_status_names[group_index % parent_status_names.size]
    done_ratio = status_name == '進行中' ? (group_index * 10) % 90 : 0

    generated_parent = seed_issue(
      project: project,
      tracker: tracker,
      status: statuses[status_name],
      priority: priority,
      author: users['pm'],
      assigned_to: assigned_to,
      subject: format('負荷テスト親-%03d', group_index),
      start_date: group_start_date.iso8601,
      due_date: (group_start_date + 9).iso8601,
      done_ratio: done_ratio
    )
  else
    child_start_date = group_start_date + item_index - 1
    status_name = status_names[(group_index + item_index) % status_names.size]
    done_ratio = status_name == '完了' ? 100 : (status_name == '進行中' ? (item_index * 10) % 100 : 0)

    seed_issue(
      project: project,
      tracker: tracker,
      status: statuses[status_name],
      priority: priority,
      author: users['pm'],
      assigned_to: assigned_to,
      subject: format('負荷テスト子-%03d-%02d', group_index, item_index),
      start_date: child_start_date.iso8601,
      due_date: (child_start_date + 2).iso8601,
      parent: generated_parent,
      done_ratio: done_ratio
    )
  end
end

puts 'Easy Gantt seed data is ready.'
