require_relative '../../../../test/test_helper'

class EasyGanttControllerTest < Redmine::ControllerTest
  def setup
    User.current = nil
    @project = Project.find(1)
    @project.enabled_module_names = (@project.enabled_module_names + %w[issue_tracking easy_gantt]).uniq
    @project.save!
    @issue = Issue.find(1)
    @request.session[:user_id] = 2
  end

  def test_update_issue_requires_standard_issue_edit_permission
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :view_easy_gantt,
        :edit_easy_gantt
      )
    )

    patch(
      :update_issue,
      params: {
        project_id: @project.identifier,
        id: @issue.id,
        issue: {
          start_date: '2026-05-01',
          due_date: '2026-05-03'
        }
      }
    )

    assert_response :forbidden
  end

  def test_index_loads_filter_metadata
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :view_easy_gantt
      )
    )

    get(
      :index,
      params: {
        project_id: @project.identifier
      }
    )

    assert_response :success
    assert_includes response.body, 'data-statuses='
    assert_includes response.body, 'data-trackers='
  end

  def test_update_issue_uses_safe_attributes_and_creates_journal
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :edit_issues,
        :view_easy_gantt,
        :edit_easy_gantt
      )
    )

    assert_difference 'Journal.count' do
      patch(
        :update_issue,
        params: {
          project_id: @project.identifier,
          id: @issue.id,
          issue: {
            start_date: '2026-05-01',
            due_date: '2026-05-03'
          }
        }
      )
    end

    assert_response :success
    @issue.reload
    assert_equal Date.iso8601('2026-05-01'), @issue.start_date
    assert_equal Date.iso8601('2026-05-03'), @issue.due_date
    assert_equal User.find(2), @issue.journals.order(:id).last.user
  end

  def test_update_issue_parent_requires_manage_subtasks_permission
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :edit_issues,
        :view_easy_gantt,
        :edit_easy_gantt
      )
    )

    patch(
      :update_issue_parent,
      params: {
        project_id: @project.identifier,
        id: @issue.id,
        issue: {
          parent_issue_id: Issue.find(2).id
        }
      }
    )

    assert_response :forbidden
  end

  def test_create_relation_requires_manage_issue_relations_permission
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :edit_issues,
        :view_easy_gantt,
        :edit_easy_gantt
      )
    )

    assert_no_difference 'IssueRelation.count' do
      post(
        :create_relation,
        params: {
          project_id: @project.identifier,
          from_id: @issue.id,
          to_id: Issue.find(2).id
        }
      )
    end

    assert_response :forbidden
  end

  def test_create_relation_requires_edit_easy_gantt_permission
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :edit_issues,
        :manage_issue_relations,
        :view_easy_gantt
      )
    )

    assert_no_difference 'IssueRelation.count' do
      post(
        :create_relation,
        params: {
          project_id: @project.identifier,
          from_id: @issue.id,
          to_id: Issue.find(2).id
        }
      )
    end

    assert_response :forbidden
    # authorize フィルタで止まることを確認する (アクション本体の手動チェックは JSON で 403 を返す)
    assert_not_equal 'application/json', response.media_type
  end

  def test_delete_relation_requires_edit_easy_gantt_permission
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :edit_issues,
        :manage_issue_relations,
        :view_easy_gantt
      )
    )

    predecessor = Issue.generate!(
      project: @project,
      tracker: @issue.tracker,
      start_date: Date.iso8601('2026-05-01'),
      due_date: Date.iso8601('2026-05-01')
    )
    successor = Issue.generate!(
      project: @project,
      tracker: @issue.tracker,
      start_date: Date.iso8601('2026-05-05'),
      due_date: Date.iso8601('2026-05-06')
    )
    relation = IssueRelation.create!(
      issue_from: predecessor,
      issue_to: successor,
      relation_type: IssueRelation::TYPE_PRECEDES,
      delay: 0
    )

    assert_no_difference 'IssueRelation.count' do
      delete(
        :delete_relation,
        params: {
          project_id: @project.identifier,
          id: relation.id
        }
      )
    end

    assert_response :forbidden
    # authorize フィルタで止まることを確認する (アクション本体の手動チェックは JSON で 403 を返す)
    assert_not_equal 'application/json', response.media_type
  end

  def test_issues_excludes_descendant_projects_without_easy_gantt_enabled
    role = role_with_permissions(
      :view_project,
      :view_issues,
      :view_easy_gantt,
      :edit_easy_gantt
    )
    user = User.find(2)
    replace_member_roles!(user, @project, role)

    child_project = Project.generate_with_parent!(@project)
    child_project.trackers = @project.trackers
    child_project.enabled_module_names = %w[issue_tracking]
    child_project.save!
    replace_member_roles!(user, child_project, role)

    hidden_issue = Issue.generate!(
      project: child_project,
      tracker: child_project.trackers.first,
      author: user,
      start_date: Date.iso8601('2026-05-01'),
      due_date: Date.iso8601('2026-05-02')
    )

    get(
      :issues,
      params: {
        project_id: @project.identifier
      }
    )

    assert_response :success
    issue_ids = JSON.parse(response.body).map {|issue| issue['id']}
    refute_includes issue_ids, hidden_issue.id
  end

  def test_issues_rejects_requests_over_display_limit
    role = role_with_permissions(
      :view_project,
      :view_issues,
      :view_easy_gantt
    )
    replace_member_roles!(User.find(2), @project, role)

    with_easy_gantt_constant(:MAX_ISSUES, 0) do
      get(
        :issues,
        params: {
          project_id: @project.identifier
        }
      )
    end

    assert_response :unprocessable_entity
  end

  def test_issues_marks_issue_not_editable_without_standard_issue_edit_permission
    replace_member_roles!(
      User.find(2),
      @project,
      role_with_permissions(
        :view_project,
        :view_issues,
        :view_easy_gantt,
        :edit_easy_gantt
      )
    )

    get(
      :issues,
      params: {
        project_id: @project.identifier
      }
    )

    assert_response :success
    issue = JSON.parse(response.body).detect {|row| row['id'] == @issue.id}
    assert_equal false, issue['editable']
  end

  def test_cascade_successor_update_creates_journal
    role = role_with_permissions(
      :view_project,
      :view_issues,
      :edit_issues,
      :manage_issue_relations,
      :view_easy_gantt,
      :edit_easy_gantt
    )
    replace_member_roles!(User.find(2), @project, role)

    predecessor = Issue.generate!(
      project: @project,
      tracker: @issue.tracker,
      start_date: Date.iso8601('2026-05-01'),
      due_date: Date.iso8601('2026-05-01')
    )
    successor = Issue.generate!(
      project: @project,
      tracker: @issue.tracker,
      start_date: Date.iso8601('2026-05-05'),
      due_date: Date.iso8601('2026-05-06')
    )
    IssueRelation.create!(
      issue_from: predecessor,
      issue_to: successor,
      relation_type: IssueRelation::TYPE_PRECEDES,
      delay: 0
    )

    assert_difference 'Journal.where(journalized_id: successor.id, journalized_type: "Issue").count' do
      patch(
        :update_issue,
        params: {
          project_id: @project.identifier,
          id: predecessor.id,
          issue: {
            start_date: '2026-05-01',
            due_date: '2026-05-10'
          }
        }
      )
    end

    assert_response :success
    successor.reload
    assert_equal Date.iso8601('2026-05-11'), successor.start_date
    assert_equal User.find(2), successor.journals.order(:id).last.user
  end

  def test_cascade_limit_rolls_back_issue_update
    role = role_with_permissions(
      :view_project,
      :view_issues,
      :edit_issues,
      :manage_issue_relations,
      :view_easy_gantt,
      :edit_easy_gantt
    )
    replace_member_roles!(User.find(2), @project, role)

    predecessor = Issue.generate!(
      project: @project,
      tracker: @issue.tracker,
      start_date: Date.iso8601('2026-05-01'),
      due_date: Date.iso8601('2026-05-01')
    )
    successor = Issue.generate!(
      project: @project,
      tracker: @issue.tracker,
      start_date: Date.iso8601('2026-05-05'),
      due_date: Date.iso8601('2026-05-06')
    )
    IssueRelation.create!(
      issue_from: predecessor,
      issue_to: successor,
      relation_type: IssueRelation::TYPE_PRECEDES,
      delay: 0
    )
    predecessor_due_date = predecessor.reload.due_date
    successor_start_date = successor.reload.start_date

    with_easy_gantt_constant(:MAX_CASCADE_ISSUES, 0) do
      patch(
        :update_issue,
        params: {
          project_id: @project.identifier,
          id: predecessor.id,
          issue: {
            start_date: '2026-05-01',
            due_date: '2026-05-10'
          }
        }
      )
    end

    assert_response :unprocessable_entity
    assert_equal predecessor_due_date, predecessor.reload.due_date
    assert_equal successor_start_date, successor.reload.start_date
  end

  private

  def role_with_permissions(*permissions)
    Role.create!(
      name: "Easy Gantt test role #{Role.maximum(:id).to_i + 1}",
      permissions: permissions
    )
  end

  def replace_member_roles!(user, project, role)
    member = Member.where(project: project, user: user).first_or_initialize
    member.roles = [role]
    member.save!
  end

  def with_easy_gantt_constant(name, value)
    previous = EasyGanttController.const_get(name)
    EasyGanttController.send(:remove_const, name)
    EasyGanttController.const_set(name, value)
    yield
  ensure
    EasyGanttController.send(:remove_const, name)
    EasyGanttController.const_set(name, previous)
  end
end
