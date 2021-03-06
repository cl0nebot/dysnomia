class PadsController < ApplicationController
  include CrudListeners
  before_action :check_availability
  before_action :set_pad, only: [:show, :edit, :update]
  decorates_assigned :pad, :pads

  # GET /pads
  # GET /pads.json
  def index
    if params[:search]
      @search = Pad.search { fulltext params[:search] }
      @pads = Pad.where(id: @search.results.map(&:id)).page(params[:page])
    else
      @pads = Pad.order(updated_at: :desc).page(params[:page])
    end

    Pad.mark_as_read! @pads.to_a, :for => current_user
  end

  # GET /pads/1
  # GET /pads/1.json
  def show
  end

  # GET /pads/new
  def new
    @pad = Pad.new
  end

  # GET /pads/1/edit
  def edit
  end

  # POST /pads
  # POST /pads.json
  def create
    @pad = etherpad_service.create pad_params

    respond_to do |format|
      format.html { redirect_to @pad, notice: 'Pad erfolgreich erstellt.' }
      format.json { render action: 'show', status: :created, location: @pad }
    end
  rescue ActiveRecord::RecordInvalid => e
    @pad = e.record

    respond_to do |format|
      format.html { render action: 'new' }
      format.json { render json: @pad.errors, status: :unprocessable_entity }
    end
  end

  # PATCH/PUT /pads/1
  # PATCH/PUT /pads/1.json
  def update
    respond_to do |format|
      if @pad.update(pad_params)
        format.html { redirect_to @pad, notice: 'Pad erfolgreich aktualisiert.' }
        format.json { head :no_content }
      else
        format.html { render action: 'edit' }
        format.json { render json: @pad.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /pads/1
  # DELETE /pads/1.json
  def destroy
    etherpad_service.destroy params[:id]
    respond_to do |format|
      format.html { redirect_to pads_url }
      format.json { head :no_content }
    end
  end

  private

  def check_availability
    unauthorized_access unless etherpad_available?
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_pad
    @pad = Pad.friendly.find(params[:id])
  end

  # Never trust parameters from the scary internet, only allow the white list through.
  def pad_params
    params.require(:pad).permit(:title, :initial_text, :url)
  end

  def etherpad_service
    @etherpad_service ||= EtherpadService.new(
      url: Settings.etherpad_address,
      version: Settings.etherpad_api_version,
      api_key: Rails.application.secrets.etherpad_api_key
    )
  end
end
