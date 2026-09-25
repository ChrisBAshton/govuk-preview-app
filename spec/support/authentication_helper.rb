module AuthenticationHelper
  def login_as(user)
    GDS::SSO.test_user = user
  end
end

RSpec.configure do |config|
  config.include AuthenticationHelper, type: :request
end
