require 'spec_helper'

describe ChefCrawler do

  describe 'crawl' do
    it 'crawles cakephp and skips all branches' do
      Product.delete_all
      expect( Product.count ).to eq(0)
      expect( License.count ).to eq(0)
      ChefCrawler.crawl true
      expect( Product.count ).to eq(10)
      expect( License.count > 1 ).to be_truthy
      expect( Dependency.count > 1 ).to be_truthy
    end
  end

end
