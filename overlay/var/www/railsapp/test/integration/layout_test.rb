require File.expand_path('../../test_helper', __FILE__)

class LayoutTest < ActionController::IntegrationTest
  fixtures :projects, :trackers, :issue_statuses, :issues,
           :enumerations, :users, :issue_categories,
           :projects_trackers,
           :roles,
           :member_roles,
           :members,
           :enabled_modules,
           :workflows

  test "browsing to a missing page should render the base layout" do
    get "/users/100000000"

    assert_response :not_found

    # UsersController uses the admin layout by default
    assert_select "#admin-menu", :count => 0
  end

  test "browsing to an unauthorized page should render the base layout" do
    change_user_password('miscuser9', 'test')

    log_user('miscuser9','test')

    get "/admin"
    assert_response :forbidden
    assert_select "#admin-menu", :count => 0
  end

  def test_top_menu_and_search_not_visible_when_login_required
    with_settings :login_required => '1' do
      get '/'
      assert_select "#top-menu > ul", 0
      assert_select "#quick-search", 0
    end
  end

  def test_top_menu_and_search_visible_when_login_not_required
    with_settings :login_required => '0' do
      get '/'
      assert_select "#top-menu > ul"
      assert_select "#quick-search"
    end
  end

  def test_wiki_formatter_header_tags
    Role.anonymous.add_permission! :add_issues

    get '/projects/ecookbook/issues/new'
    assert_tag :script,
      :attributes => {:src => %r{^/javascripts/jstoolbar/textile.js}},
      :parent => {:tag => 'head'}
  end

  def test_search_field_outside_project_should_link_to_global_search
    get '/'
    assert_select 'div#quick-search form[action=/search]'
  end

  def test_search_field_inside_project_should_link_to_project_search
    get '/projects/ecookbook'
    assert_select 'div#quick-search form[action=/projects/ecookbook/search]'
  end
end
