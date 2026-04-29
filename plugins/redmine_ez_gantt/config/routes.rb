resources :projects, only: [] do
  get 'easy_gantt', to: 'easy_gantt#index'
  get 'easy_gantt/issues', to: 'easy_gantt#issues'
  get 'easy_gantt/relations', to: 'easy_gantt#relations'
end

patch 'easy_gantt/issues/:id', to: 'easy_gantt#update_issue'
patch 'easy_gantt/issues/:id/parent', to: 'easy_gantt#update_issue_parent'
post 'easy_gantt/relations', to: 'easy_gantt#create_relation'
delete 'easy_gantt/relations/:id', to: 'easy_gantt#delete_relation'
