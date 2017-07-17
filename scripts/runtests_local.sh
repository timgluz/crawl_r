#!/bin/bash

echo "Going to run all specs"
export RAILS_ENV="test"
echo "Rails mode: $RAILS_ENV"

rspec spec/* --format documentation

export RAILS_ENV="development"
echo "Rails mode: $RAILS_ENV"
