# frozen_string_literal: true

require "test_helper"

class ControllerEtagTest < ActionDispatch::IntegrationTest
  test "include_assiette_etags! folds the apex digest into the ETag" do
    get "/etagged"
    assert_response :success
    with_digest = response.headers["ETag"]
    assert with_digest.present?

    get "/plain_etagged"
    assert_response :success
    without_digest = response.headers["ETag"]

    assert_not_equal without_digest, with_digest,
      "the same validator must produce a different ETag once the digest is folded in"
  end

  test "the ETag is stable across requests" do
    get "/etagged"
    first = response.headers["ETag"]

    get "/etagged"
    assert_equal first, response.headers["ETag"]

    get "/etagged", headers: {"HTTP_IF_NONE_MATCH" => first}
    assert_response :not_modified
  end
end
