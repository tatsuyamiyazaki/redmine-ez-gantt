resources :projects, only: [] do
  get 'easy_gantt', to: 'easy_gantt#index'
  get 'easy_gantt/issues', to: 'easy_gantt#issues'
end

patch 'easy_gantt/issues/:id', to: 'easy_gantt#update_issue'
patch 'easy_gantt/issues/:id/parent', to: 'easy_gantt#update_issue_parent'
