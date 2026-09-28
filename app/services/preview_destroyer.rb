# Stops/removes a preview's container, database (if any) and checkout, then
# destroys its record - recursing into its dependents *first*, since each
# owns its own container/DB/checkout that a plain AR `dependent: :destroy`
# can't clean up (see Preview#dependents).
class PreviewDestroyer
  attr_reader :preview

  def initialize(preview)
    @preview = preview
  end

  def destroy!
    preview.dependents.each { |dependent| self.class.new(dependent).destroy! }

    DockerRunner.new(preview).stop!

    database = GovukApps.find(preview.app_name)&.database
    DatabaseRunner.new(preview, database).stop! if database

    Checkout.new(preview).remove!

    preview.destroy!
  end
end
