require 'swagger_helper'

describe 'Endpoint failure diagnoses', type: :request do
  let(:owner) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:diagnoser) { instance_double(Ai::GeminiFailureDiagnoser, call: nil, analyzed_attempt_count: 1) }

  before { allow(Ai::GeminiFailureDiagnoser).to receive(:new).and_return(diagnoser) }

  def diagnose(user: owner, target_project: project, target_endpoint: endpoint)
    post "/api/v1/projects/#{target_project.id}/endpoints/#{target_endpoint.id}/diagnoses",
         headers: auth_headers(user)
  end

  describe 'POST /api/v1/projects/:project_id/endpoints/:endpoint_id/diagnoses' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        post "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/diagnoses"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the user is a project member' do
      it 'saves a diagnosis and returns only the public fields' do
        create(:delivery_attempt, message: create(:message, project: project, endpoint: endpoint, status: :failed),
                                  response_status: 500)

        diagnose

        expect(response).to have_http_status(:created)
        expect(json_response.keys).to contain_exactly('label', 'suggested_action', 'source', 'created_at')
        expect(json_response).to include(
          'label' => Ai::Diagnosis::UNKNOWN,
          'source' => EndpointDiagnosis::SOURCE_FALLBACK
        )
        expect(json_response['suggested_action']).to be_present

        diagnosis = EndpointDiagnosis.last
        expect(diagnosis).to have_attributes(
          endpoint_id: endpoint.id,
          project_id: project.id,
          requested_by_id: owner.id,
          analyzed_attempt_count: 1
        )
      end

      it 'returns the ai label when the provider answer is validated' do
        allow(diagnoser).to receive(:call).and_return(
          Ai::Diagnosis::Result.new(
            label: Ai::Diagnosis::RATE_LIMITED,
            suggested_action: 'Ask the receiver to accept a slower retry rate.',
            source: Ai::Diagnosis::SOURCE_AI,
            model: 'gemini-test-model'
          )
        )

        diagnose

        expect(response).to have_http_status(:created)
        expect(json_response).to include('label' => Ai::Diagnosis::RATE_LIMITED,
                                         'source' => EndpointDiagnosis::SOURCE_AI)
      end

      it 'never leaks provider details when the provider answer is unusable' do
        allow(diagnoser).to receive(:call).and_return(nil)

        diagnose

        expect(response).to have_http_status(:created)
        expect(response.body).not_to include('gemini', 'generativelanguage', 'candidates')
      end

      it 'does not enqueue delivery work or change delivery state' do
        message = create(:message, project: project, endpoint: endpoint, status: :failed)
        delivery = create(:delivery_attempt, message: message, response_status: 500)
        before_state = [message.reload.attributes, delivery.reload.attributes, endpoint.reload.attributes]

        diagnose

        expect(message.reload.attributes).to eq(before_state[0])
        expect(delivery.reload.attributes).to eq(before_state[1])
        expect(endpoint.reload.attributes).to eq(before_state[2])
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end
    end

    context 'when the endpoint belongs to another project' do
      it 'is not found' do
        other_project = create(:project, :with_owner, owner: owner)
        other_endpoint = create(:endpoint, project: other_project)

        diagnose(target_project: project, target_endpoint: other_endpoint)

        expect(response).to have_http_status(:not_found)
        expect(EndpointDiagnosis.count).to eq(0)
      end
    end

    context 'when the user can not access the project' do
      it 'is not found' do
        diagnose(user: outsider)

        expect(response).to have_http_status(:not_found)
        expect(EndpointDiagnosis.count).to eq(0)
      end
    end
  end

  describe 'GET /api/v1/projects/:project_id/endpoints/:endpoint_id/diagnoses/latest' do
    def latest(user: owner, target_project: project, target_endpoint: endpoint)
      get "/api/v1/projects/#{target_project.id}/endpoints/#{target_endpoint.id}/diagnoses/latest",
          headers: auth_headers(user)
    end

    context 'when unauthenticated' do
      it 'requires authentication' do
        get "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/diagnoses/latest"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the user is a project member' do
      it 'returns the persisted diagnosis with only the public fields' do
        diagnosis = create(:endpoint_diagnosis, :ai, endpoint: endpoint, project: project, requested_by: owner)

        latest

        expect(response).to have_http_status(:ok)
        expect(json_response.keys).to contain_exactly('label', 'suggested_action', 'source', 'created_at')
        expect(json_response).to include(
          'label' => diagnosis.label,
          'suggested_action' => diagnosis.suggested_action,
          'source' => diagnosis.source
        )
        expect(Time.zone.parse(json_response['created_at'])).to be_within(1.second).of(diagnosis.created_at)
      end

      it 'returns the newest diagnosis when the endpoint has several' do
        stale = create(:endpoint_diagnosis, :ai, endpoint: endpoint, project: project, requested_by: owner,
                                               created_at: 2.hours.ago)
        newest = create(:endpoint_diagnosis, endpoint: endpoint, project: project, requested_by: owner,
                                             created_at: 1.hour.ago)

        latest

        expect(response).to have_http_status(:ok)
        expect(json_response['label']).to eq(newest.label)
        expect(json_response['label']).not_to eq(stale.label)
      end

      it 'ignores diagnoses that belong to another endpoint' do
        other_endpoint = create(:endpoint, project: project)
        create(:endpoint_diagnosis, endpoint: other_endpoint, project: project, requested_by: owner)

        latest

        expect(response).to have_http_status(:no_content)
      end

      it 'has no content when the endpoint has no diagnosis yet' do
        expect { latest }.not_to change(EndpointDiagnosis, :count)

        expect(response).to have_http_status(:no_content)
        expect(response.body).to be_blank
      end

      it 'never creates records or changes delivery state' do
        message = create(:message, project: project, endpoint: endpoint, status: :failed)
        delivery = create(:delivery_attempt, message: message, response_status: 500)
        create(:endpoint_diagnosis, endpoint: endpoint, project: project, requested_by: owner)
        before_state = [message.reload.attributes, delivery.reload.attributes, endpoint.reload.attributes,
                        project.reload.attributes]
        usage_before = UserUsagePeriod.order(:id).map(&:attributes)

        latest

        expect(response).to have_http_status(:ok)
        expect(EndpointDiagnosis.count).to eq(1)
        expect(CircuitProbe.count).to eq(0)
        expect(message.reload.attributes).to eq(before_state[0])
        expect(delivery.reload.attributes).to eq(before_state[1])
        expect(endpoint.reload.attributes).to eq(before_state[2])
        expect(project.reload.attributes).to eq(before_state[3])
        expect(UserUsagePeriod.order(:id).map(&:attributes)).to eq(usage_before)
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end
    end

    context 'when the user can not access the project' do
      it 'is not found' do
        create(:endpoint_diagnosis, endpoint: endpoint, project: project, requested_by: owner)

        latest(user: outsider)

        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the endpoint belongs to another project' do
      it 'is not found' do
        other_project = create(:project, :with_owner, owner: owner)
        other_endpoint = create(:endpoint, project: other_project)
        create(:endpoint_diagnosis, endpoint: other_endpoint, project: other_project, requested_by: owner)

        latest(target_project: project, target_endpoint: other_endpoint)

        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the endpoint does not exist' do
      it 'is not found' do
        get "/api/v1/projects/#{project.id}/endpoints/#{SecureRandom.uuid}/diagnoses/latest",
            headers: auth_headers(owner)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
