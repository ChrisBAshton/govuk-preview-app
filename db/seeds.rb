if GDS::SSO::Config.use_mock_strategies?
  User.find_or_create_by!(uid: "test-uid") do |user|
    user.name = "Test User"
    user.email = "test@example.com"
    user.permissions = %w[signin]
  end
end
