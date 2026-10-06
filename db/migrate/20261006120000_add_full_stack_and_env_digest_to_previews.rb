# full_stack: whether a top-level preview's stack includes its apps'
# `full_stack_dependencies` (e.g. Content Stores and Frontends) - see
# PreviewBuilder. Previews default to the lighter core stack.
#
# env_digest: which dependency addresses a running preview was last started
# with, so a change of stack size can tell which running previews need
# restarting with new ones (PreviewBuilder#reconfigure!).
class AddFullStackAndEnvDigestToPreviews < ActiveRecord::Migration[8.1]
  def change
    change_table :previews, bulk: true do |t|
      t.boolean :full_stack, default: false, null: false
      t.string :env_digest
    end
  end
end
