Redmine::Plugin.register :redmine_easy_gantt do
  name 'Easy Gantt'
  author 'redmine-easy-gantt'
  description 'A project Gantt chart plugin for Redmine.'
  version '0.0.1'
  requires_redmine version_or_higher: '6.0.0'

  project_module :easy_gantt do
    permission :view_easy_gantt, { easy_gantt: [:index, :issues, :relations] }, require: :member
    permission :edit_easy_gantt, { easy_gantt: [:index, :update_issue, :update_issue_parent, :create_relation, :delete_relation] }, require: :member
  end

  menu :project_menu,
       :easy_gantt,
       { controller: 'easy_gantt', action: 'index' },
       caption: :label_easy_gantt,
       after: :gantt,
       param: :project_id
end
