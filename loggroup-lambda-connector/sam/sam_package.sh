#!/bin/bash

SAM_S3_BUCKET="kbs-sumologic-connector"
AWS_REGION="us-west-2"
LOG_GROUP_PATTERN="\/aws\/(lambda|fargate)\/(?!(kanaha|rdb|wasaga|.+?_producer_|workday\-producers)).+"

version="1.0.4"

sam package --template-file template.yaml --s3-bucket $SAM_S3_BUCKET  --output-template-file packaged.yaml --s3-prefix "LoggroupConnector/v$version"

# sam deploy --template-file packaged.yaml --stack-name testingloggrpconnector --capabilities CAPABILITY_IAM --region $AWS_REGION  --parameter-overrides LambdaARN="arn:aws:lambda:us-east-1:956882708938:function:SumoCWLogsLambda" LogGroupTags="env=prod,name=apiassembly" LogGroupPattern="test"

sam deploy --no-execute-changeset --capabilities CAPABILITY_IAM --stack-name serverlessrepo-sumologic-loggroup-connector --template packaged.yaml --region $AWS_REGION --parameter-overrides LogGroupPattern=$LOG_GROUP_PATTERN UseExistingLogs="true" DestinationArnValue="arn:aws:lambda:us-west-2:529513974030:function:SumoCWLogsLambda-33c639e0-1d57-11e9-ae4a-0ae846f1e916"
# aws cloudformation describe-stack-events --stack-name testingloggrpconnector --region $AWS_REGION
# aws cloudformation get-template --stack-name testingloggrpconnector  --region $AWS_REGION

