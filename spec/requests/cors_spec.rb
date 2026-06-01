require 'rails_helper'

RSpec.describe 'CORS', type: :request do
  it 'allows the local frontend origin and exposes the Authorization header' do
    get '/health', headers: { 'Origin' => 'http://localhost:3000' }

    expect(response.headers['Access-Control-Allow-Origin']).to eq('http://localhost:3000')
    expect(response.headers['Access-Control-Expose-Headers']).to include('Authorization')
  end

  it 'allows the configured production frontend origin from FRONTEND_URL' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('FRONTEND_URL').and_return('https://ticketforge.vercel.app')

    get '/health', headers: { 'Origin' => 'https://ticketforge.vercel.app' }

    expect(response.headers['Access-Control-Allow-Origin']).to eq('https://ticketforge.vercel.app')
  end
end
