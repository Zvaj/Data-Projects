#!/usr/bin/env bash
set -euo pipefail

#######################################
# 1. Prep
#######################################

#######################################
# CONFIG – EDIT THESE VALUES
#######################################
AWS_REGION="us-east-1"                 # region
CLIENT_IP="YOUR.PUBLIC.IP.HERE"        # e.g. 73.221.xxx.xxx (no /32)
INSTANCE_NAME="kaggle-downloader"
INSTANCE_TYPE="t2.micro"              # matches assignment; bump if you want more CPU/RAM
VOLUME_SIZE=30                        # GiB; 15 is bare minimum for 3GB dataset, 30 is safer

# S3 bucket (auto-generated, globally unique-ish)
BUCKET_NAME="s3-wth-$(uuidgen | tr 'A-Z' 'a-z')"   # e.g. s3-wth-xxxx
DATA_PREFIX="data"                                 # s3://bucket/data/

# IAM role / instance profile names
ROLE_NAME="${INSTANCE_NAME}-role"
INSTANCE_PROFILE_NAME="${INSTANCE_NAME}-instance-profile"

echo "=== Using region: ${AWS_REGION} ==="
aws configure set region "${AWS_REGION}"

#######################################
# a. Create S3 bucket + data/ prefix
#######################################
echo "Creating S3 bucket: ${BUCKET_NAME} ..."

if [ "${AWS_REGION}" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}"
else
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"
fi

echo "Bucket created: s3://${BUCKET_NAME}"

echo "Creating prefix s3://${BUCKET_NAME}/${DATA_PREFIX}/ ..."
aws s3api put-object \
  --bucket "${BUCKET_NAME}" \
  --key "${DATA_PREFIX}/"

echo "S3 ready at: s3://${BUCKET_NAME}/${DATA_PREFIX}/"


#######################################
# b. Create IAM Role + Instance Profile
#######################################
echo "Creating IAM role: ${ROLE_NAME} for EC2..."

# Trust policy so EC2 instances can assume this role
cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create the role (ignore error if it already exists)
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
  >/dev/null 2>&1 || echo "Role ${ROLE_NAME} may already exist, continuing..."

echo "Attaching policies to role ${ROLE_NAME} ..."

# Give the instance S3 access (you can narrow this later with a custom policy)
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# (Optional but nice) allow SSM Session Manager
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Create instance profile if needed
aws iam create-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
  >/dev/null 2>&1 || echo "Instance profile ${INSTANCE_PROFILE_NAME} may already exist, continuing..."

# Add role to instance profile (idempotent-ish)
aws iam add-role-to-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
  --role-name "${ROLE_NAME}" \
  >/dev/null 2>&1 || echo "Role ${ROLE_NAME} may already be in instance profile, continuing..."

echo "IAM role and instance profile ready."
echo "  Role:             ${ROLE_NAME}"
echo "  Instance profile: ${INSTANCE_PROFILE_NAME}"

# Small sleep to let IAM propagate (helps avoid 'No such entity' race conditions)
sleep 10


#######################################
# c. Find default VPC
#######################################
echo "Finding default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text)

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  echo "ERROR: No default VPC found. Create one or specify VPC_ID manually."
  exit 1
fi

echo "Default VPC: ${VPC_ID}"

#######################################
# d. Create Security Group for SSH
#######################################
SG_NAME="${INSTANCE_NAME}-sg"

echo "Creating security group: ${SG_NAME} ..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "${SG_NAME}" \
  --description "Security group for ${INSTANCE_NAME} (SSH from client IP)" \
  --vpc-id "${VPC_ID}" \
  --query 'GroupId' \
  --output text)

echo "Security Group ID: ${SG_ID}"

# Allow SSH from your IP only
echo "Authorizing SSH (22) from ${CLIENT_IP}/32 ..."
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 22 \
  --cidr "${CLIENT_IP}/32"


#######################################
# e. Get latest Amazon Linux 2023 AMI
#######################################
echo "Getting latest Amazon Linux 2023 AMI ID via SSM..."
AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

AMI_ID=$(aws ssm get-parameters \
  --names "${AMI_PARAM}" \
  --region "${AWS_REGION}" \
  --query "Parameters[0].Value" \
  --output text)

if [ -z "${AMI_ID}" ] || [ "${AMI_ID}" = "None" ]; then
  echo "ERROR: Could not lookup Amazon Linux 2023 AMI via SSM."
  exit 1
fi

echo "Using AMI: ${AMI_ID}"

#######################################
# f. Launch EC2 instance (with IAM role)
#######################################
echo "Launching EC2 instance ${INSTANCE_NAME} ..."

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --security-group-ids "${SG_ID}" \
  --iam-instance-profile Name="${INSTANCE_PROFILE_NAME}" \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${VOLUME_SIZE},VolumeType=gp3,DeleteOnTermination=true}" \
  --count 1 \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "Instance ID: ${INSTANCE_ID}"

echo "Waiting for instance to enter 'running' state..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

PUBLIC_DNS=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query "Reservations[0].Instances[0].PublicDnsName" \
  --output text)

echo "Instance is running."
echo "  ID:   ${INSTANCE_ID}"
echo "  IP:   ${PUBLIC_IP}"
echo "  DNS:  ${PUBLIC_DNS}"

cat <<EOF
============================================================
SETUP COMPLETE

S3 bucket:
  s3://${BUCKET_NAME}/${DATA_PREFIX}/

EC2 instance:
  Name:        ${INSTANCE_NAME}
  Instance ID: ${INSTANCE_ID}
  Public IP:   ${PUBLIC_IP}
  Public DNS:  ${PUBLIC_DNS}
  Security Group: ${SG_ID} (SSH allowed from ${CLIENT_IP}/32)
  IAM Role:        ${ROLE_NAME}
  Instance Profile:${INSTANCE_PROFILE_NAME}

NEXT STEPS:
1) In the AWS Console → EC2 → Instances.
2) Find the instance named "${INSTANCE_NAME}".
3) Click "Connect" → "EC2 Instance Connect" → Connect.

Once you are connected to the instance, run the *second* script
(02_kaggle_to_s3_on_ec2.sh) with:

  BUCKET_NAME="${BUCKET_NAME}"

ALSO:
Make sure your IAM *user* or role has the policy:
  arn:aws:iam::aws:policy/AmazonEC2InstanceConnect
so EC2 Instance Connect can send the SSH public key.

============================================================
EOF




# ////////////////////////////////////////////////////
#######################################
# 2. RUN in EC2 Instance after it is connected
#######################################
# Update system packages
sudo yum update
sudo yum install awscli

# Configure AWS CLI
aws configure
# Enter your AWS access key, secret key, region, and preferred output format

# Install Python and pip
sudo yum install python3
sudo yum install python3-pip

# Verify pip installation
pip3 --version

# Install Kaggle API
pip3 install kaggle

# Set up Kaggle credentials
mkdir ~/.kaggle
nano ~/.kaggle/kaggle.json

# change it depending on your kaggle info
{
    "username": "your-username",
    "key": "your-api-key"
}

chmod 600 ~/.kaggle/kaggle.json

#######################################
# a. RUN in EC2 Instance after it is connected
#######################################
# Download the dataset
cd ~
kaggle datasets download -d "pcovkrd84mejm/tabred-weather"

# Unzip the downloaded file
unzip tabred-weather.zip

# Upload to S3
aws s3 cp data s3://your-bucket-name/data --recursive

# double-check that data is in the bucket manually.

#######################################
# b. FROM HERE DELETE the Kaggle Downloader EC2 Instance
#######################################
if [ -z "$INSTANCE_ID" ]; then
  echo "ERROR: No running/stopped EC2 instance found with Name=${INSTANCE_NAME}"
  exit 1
fi

echo "Found instance: $INSTANCE_ID"
echo "Terminating..."

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"

echo "Waiting for termination..."
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

echo "Instance '${INSTANCE_NAME}' (${INSTANCE_ID}) has been terminated."



# ////////////////////////////////////////////////////
#######################################
# 3. Preparing for the Data Cleaning, Analytics, and Visualization
#######################################
# Create an EMR
#!/usr/bin/env bash
set -euo pipefail

#######################################
# CONFIG – EDIT THESE VALUES
#######################################
AWS_REGION="us-east-1"          # change if needed
CLUSTER_NAME="weather-emr-cluster"
KEY_NAME="weather-emr-key"      # SSH key pair name in EC2
KEY_FILE="${KEY_NAME}.pem"      # local .pem file
LOG_BUCKET="s3-weather-emr-logs-$(uuidgen | tr 'A-Z' 'a-z')"  # S3 for EMR logs

# EMR hardware config
MASTER_INSTANCE_TYPE="m5.xlarge"
CORE_INSTANCE_TYPE="m5.xlarge"
CORE_INSTANCE_COUNT=2           # 1 master + 2 core = 3 nodes total

#######################################
# a. Set region
#######################################
echo "=== Using region: ${AWS_REGION} ==="
aws configure set region "${AWS_REGION}"

#######################################
# b. Ensure S3 log bucket exists
#######################################
echo "Creating S3 log bucket: ${LOG_BUCKET} (if it doesn't exist)..."

if [ "${AWS_REGION}" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "${LOG_BUCKET}" \
    >/dev/null 2>&1 || echo "Log bucket may already exist, continuing..."
else
  aws s3api create-bucket \
    --bucket "${LOG_BUCKET}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}" \
    >/dev/null 2>&1 || echo "Log bucket may already exist, continuing..."
fi

echo "Log bucket: s3://${LOG_BUCKET}/"

#######################################
# c. Ensure SSH key pair exists
#######################################
if [ ! -f "${KEY_FILE}" ]; then
  echo "Creating EC2 key pair: ${KEY_NAME} ..."
  aws ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --query 'KeyMaterial' \
    --output text > "${KEY_FILE}"

  chmod 400 "${KEY_FILE}"
  echo "Saved key to ${KEY_FILE}"
else
  echo "Key file ${KEY_FILE} already exists; using existing key pair name ${KEY_NAME}."
fi

#######################################
# d. Ensure EMR default roles exist
#######################################
echo "Ensuring EMR default IAM roles exist..."
aws emr create-default-roles >/dev/null 2>&1 || echo "Default EMR roles already exist."

#######################################
# e. Find a default subnet for EMR
#######################################
echo "Finding a default subnet to launch EMR in..."
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query "Subnets[0].SubnetId" \
  --output text)

if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" = "None" ]; then
  echo "ERROR: No default subnet found. Please specify a SUBNET_ID manually in the script."
  exit 1
fi

echo "Using subnet: ${SUBNET_ID}"

#######################################
# f. Create EMR cluster with Spark
#######################################
echo "Creating EMR cluster: ${CLUSTER_NAME} ..."

CLUSTER_ID=$(aws emr create-cluster \
  --name "${CLUSTER_NAME}" \
  --release-label "emr-6.15.0" \
  --applications Name=Hadoop Name=Spark \
  --ec2-attributes KeyName="${KEY_NAME}",SubnetId="${SUBNET_ID}" \
  --instance-groups \
      InstanceGroupType=MASTER,InstanceCount=1,InstanceType="${MASTER_INSTANCE_TYPE}" \
      InstanceGroupType=CORE,InstanceCount="${CORE_INSTANCE_COUNT}",InstanceType="${CORE_INSTANCE_TYPE}" \
  --use-default-roles \
  --log-uri "s3://${LOG_BUCKET}/emr-logs/" \
  --enable-debugging \
  --auto-terminate false \
  --query "ClusterId" \
  --output text)

echo "Cluster created. ID: ${CLUSTER_ID}"

#######################################
# g. Wait for cluster to be running
#######################################
echo "Waiting for EMR cluster to be in 'WAITING' or 'RUNNING' state..."
aws emr wait cluster-running --cluster-id "${CLUSTER_ID}"

#######################################
# h. Get master public DNS
#######################################
MASTER_DNS=$(aws emr describe-cluster \
  --cluster-id "${CLUSTER_ID}" \
  --query "Cluster.MasterPublicDnsName" \
  --output text)

echo
echo "================================================="
echo "EMR cluster is ready."
echo "Cluster ID : ${CLUSTER_ID}"
echo "Master DNS : ${MASTER_DNS}"
echo "Log bucket : s3://${LOG_BUCKET}/emr-logs/"
echo "================================================="
echo
echo "To SSH from this machine (Cloud9 or local), run:"
echo
echo "  ssh -i \"${KEY_FILE}\" hadoop@${MASTER_DNS}"
echo
echo "Once on the master node, you can start PySpark with:"
echo
echo "  pyspark"
echo
echo "Or submit your ETL job with:"
echo
echo "  spark-submit spark_weather_pipeline.py"
echo



# ////////////////////////////////////////////////////
#######################################
# 3. Now let us run this in our EMR
#######################################
# pyspark_weather_emr.py
# Run inside EMR (pyspark or spark-submit)
# Translated from your pandas/sklearn workflow into PySpark + Spark ML

from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, when, count, countDistinct, avg, mean as _mean
)
from pyspark.ml.feature import VectorAssembler, StandardScaler
from pyspark.ml.regression import LinearRegression, RandomForestRegressor
from pyspark.ml.clustering import KMeans
from pyspark.ml.evaluation import RegressionEvaluator, ClusteringEvaluator
from pyspark.ml import Pipeline

# Optional plotting (sampled to pandas)
import matplotlib.pyplot as plt
import seaborn as sns

# -------------------------------------------
# a. Spark Session
# -------------------------------------------
spark = SparkSession.builder \
    .appName("Weather-EMR-ETL-ML") \
    .getOrCreate()

spark.sparkContext.setLogLevel("WARN")

# -------------------------------------------
# b. Load Data (from S3 or local)
# -------------------------------------------
# Example: S3 CSV
# INPUT_PATH = "s3://your-bucket/data/weather_preview.csv"
# or if you already have curated parquet:
# INPUT_PATH = "s3://your-bucket/curated/"

INPUT_PATH = "s3://your-bucket/data/weather_preview.csv"  # <<< CHANGE THIS
OUTPUT_CLEAN_PATH = "s3://your-bucket/curated_pyspark/"   # <<< CHANGE IF YOU LIKE

print(f"Reading data from: {INPUT_PATH}")

# If CSV:
df = spark.read \
    .option("header", "true") \
    .option("inferSchema", "true") \
    .csv(INPUT_PATH)

print("Schema:")
df.printSchema()

row_count = df.count()
col_count = len(df.columns)
print(f"Rows: {row_count:,} | Columns: {col_count:,}")

print("First 5 rows:")
df.show(5, truncate=False)

# -------------------------------------------
# c. EDA-like Info
# -------------------------------------------

# Data types
print("Data types:")
print(df.dtypes)

# Missing values per column
print("\nMissing values per column:")
null_counts = df.select([
    count(when(col(c).isNull(), c)).alias(c) for c in df.columns
])
null_counts.show(truncate=False)

# Duplicate rows count
dup_count = df.count() - df.dropDuplicates().count()
print(f"\nDuplicate rows: {dup_count}")

# Unique counts per column
print("\nUnique counts per column:")
unique_counts_exprs = [countDistinct(col(c)).alias(c) for c in df.columns]
df.select(unique_counts_exprs).show(truncate=False)

# Descriptive stats for numeric columns
numeric_cols = [c for c, t in df.dtypes if t in ("int", "bigint", "float", "double", "long")]
print("\nDescriptive statistics (numeric columns):")
df.select(numeric_cols).describe().show(truncate=False)

# -------------------------------------------
# d. Outlier Detection (IQR) – counts only
# -------------------------------------------
print("\nOutlier counts by numeric column (IQR-based):")
for c in numeric_cols:
    # approxQuantile returns [Q1, Q3]
    q1, q3 = df.approxQuantile(c, [0.25, 0.75], 0.01)
    iqr = q3 - q1
    lower = q1 - 1.5 * iqr
    upper = q3 + 1.5 * iqr
    outlier_count = df.filter((col(c) < lower) | (col(c) > upper)).count()
    print(f"  {c}: {outlier_count} potential outliers")

# -------------------------------------------
# e. Cleaning / Preparation
#    - Imputed flags
#    - Mean imputation for numeric columns
#    - IQR clipping
# -------------------------------------------

from pyspark.sql.functions import isnan

df_clean = df

# track imputed cells (flags BEFORE imputation)
for c in numeric_cols:
    flag_col = f"{c}_imputed"
    df_clean = df_clean.withColumn(
        flag_col,
        when(col(c).isNull() | isnan(col(c)), 1).otherwise(0)
    )

# simple mean imputation for numeric columns
means_row = df_clean.select([avg(c).alias(c) for c in numeric_cols]).first()
mean_dict = {c: means_row[c] for c in numeric_cols}

df_clean = df_clean.na.fill(mean_dict)

# IQR clipping
for c in numeric_cols:
    q1, q3 = df_clean.approxQuantile(c, [0.25, 0.75], 0.01)
    iqr = q3 - q1
    lower = q1 - 1.5 * iqr
    upper = q3 + 1.5 * iqr
    df_clean = df_clean.withColumn(
        c,
        when(col(c) < lower, lower)
        .when(col(c) > upper, upper)
        .otherwise(col(c))
    )

print("\nPreview of cleaned data:")
df_clean.show(5, truncate=False)

# Save cleaned data as Parquet to S3 (Spark-native format)
print(f"\nWriting cleaned data to: {OUTPUT_CLEAN_PATH}")
df_clean.write.mode("overwrite").parquet(OUTPUT_CLEAN_PATH)
print("Done writing cleaned data.")

# -------------------------------------------
# f. Analysis / Modeling Setup
# -------------------------------------------

# We’ll keep working with df_clean
target_col = "climate_temperature"  # must exist in df
if target_col not in df_clean.columns:
    raise ValueError(f"Target column '{target_col}' not found in data.")

# Feature columns: numeric and NOT the target
feature_cols = [c for c in numeric_cols if c != target_col]

print("\nFeature columns used for modeling:")
print(feature_cols)
print("\nTarget column:")
print(target_col)

# Train / test split (80/20)
train_df, test_df = df_clean.randomSplit([0.8, 0.2], seed=42)

# Assemble features
assembler = VectorAssembler(inputCols=feature_cols, outputCol="features")

# For linear regression, we’ll scale features
scaler = StandardScaler(inputCol="features", outputCol="features_scaled",
                        withStd=True, withMean=True)

# -------------------------------------------
# g. MODEL 1: Linear Regression (Spark ML)
# -------------------------------------------
lr = LinearRegression(featuresCol="features_scaled", labelCol=target_col)

pipeline_lr = Pipeline(stages=[assembler, scaler, lr])
lr_model = pipeline_lr.fit(train_df)

pred_lr = lr_model.transform(test_df)

evaluator_mae = RegressionEvaluator(
    labelCol=target_col, predictionCol="prediction", metricName="mae"
)
evaluator_r2 = RegressionEvaluator(
    labelCol=target_col, predictionCol="prediction", metricName="r2"
)

mae_lr = evaluator_mae.evaluate(pred_lr)
r2_lr = evaluator_r2.evaluate(pred_lr)

print("\n=== Linear Regression Performance (Spark ML) ===")
print(f"  MAE: {mae_lr}")
print(f"  R² : {r2_lr}")

# -------------------------------------------
# h. MODEL 2: Random Forest Regression (Spark ML)
# -------------------------------------------
rf = RandomForestRegressor(
    featuresCol="features",
    labelCol=target_col,
    numTrees=200,
    seed=42
)

pipeline_rf = Pipeline(stages=[assembler, rf])
rf_model = pipeline_rf.fit(train_df)

pred_rf = rf_model.transform(test_df)

mae_rf = evaluator_mae.evaluate(pred_rf)
r2_rf = evaluator_r2.evaluate(pred_rf)

print("\n=== Random Forest Performance (Spark ML) ===")
print(f"  MAE: {mae_rf}")
print(f"  R² : {r2_rf}")

# Feature importances
rf_stage = rf_model.stages[-1]  # the RandomForestRegressor stage
importances = list(rf_stage.featureImportances)

feature_importance_pairs = sorted(
    zip(feature_cols, importances),
    key=lambda x: x[1],
    reverse=True
)

print("\nTop Feature Importances (Random Forest):")
for name, imp in feature_importance_pairs[:10]:
    print(f"  {name}: {imp}")

# -------------------------------------------
# i. MODEL 3: Weather Pattern Clustering (KMeans)
# -------------------------------------------

cluster_features = [
    "climate_pressure",
    "climate_temperature",
    "gfs_humidity",
    "gfs_wind_speed",
    "gfs_precipitations"
]

for cf in cluster_features:
    if cf not in df_clean.columns:
        raise ValueError(f"Cluster feature '{cf}' not found in data.")

# Drop rows with nulls in cluster features
cluster_df = df_clean.dropna(subset=cluster_features)

cluster_assembler = VectorAssembler(
    inputCols=cluster_features,
    outputCol="features_cluster"
)
cluster_scaler = StandardScaler(
    inputCol="features_cluster",
    outputCol="features_cluster_scaled",
    withStd=True,
    withMean=True
)
kmeans = KMeans(
    featuresCol="features_cluster_scaled",
    predictionCol="cluster",
    k=4,
    seed=42
)

pipeline_km = Pipeline(stages=[cluster_assembler, cluster_scaler, kmeans])
kmeans_model = pipeline_km.fit(cluster_df)
cluster_result = kmeans_model.transform(cluster_df)

# Centroids (scaled space)
kmeans_stage = kmeans_model.stages[-1]
centers = kmeans_stage.clusterCenters()

print("\nCluster centroids (scaled space):")
for idx, center in enumerate(centers):
    print(f"  Cluster {idx}: {center}")

# Silhouette score
clust_eval = ClusteringEvaluator(
    featuresCol="features_cluster_scaled",
    predictionCol="cluster",
    metricName="silhouette"
)
silhouette = clust_eval.evaluate(cluster_result)
print(f"\nSilhouette Score: {silhouette}")

# Cluster distribution
print("\nCluster distribution (counts):")
cluster_result.groupBy("cluster").count().show()

# Cluster summary (mean of features)
from pyspark.sql.functions import mean as _mean
print("\nCluster summary (mean of cluster features):")
agg_exprs = [_mean(c).alias(f"avg_{c}") for c in cluster_features]
cluster_result.groupBy("cluster").agg(*agg_exprs).show(truncate=False)

# -------------------------------------------
# j. Optional: Plotting in PySpark (sample to pandas)
#    (Only for small samples to avoid driver OOM)
# -------------------------------------------

# Sample small subset for plotting (e.g., 1% of data)
sample_frac = 0.01
plot_sample = cluster_result.select(
    "climate_pressure", "climate_temperature", "cluster"
).sample(False, sample_frac, seed=42)

pd_sample = plot_sample.toPandas()

# Scatter: Pressure vs Temperature colored by cluster
plt.figure(figsize=(8, 6))
sns.scatterplot(
    data=pd_sample,
    x="climate_pressure",
    y="climate_temperature",
    hue="cluster",
    palette="viridis",
    alpha=0.7
)
plt.title("Weather Pattern Clusters by Pressure and Temperature", fontsize=14)
plt.xlabel("Climate Pressure (hPa)")
plt.ylabel("Climate Temperature (°C)")
plt.legend(title="Cluster", loc="best")
plt.grid(alpha=0.3)
plt.tight_layout()
plt.show()

# Another scatter + regression line (aggregate)
plt.figure(figsize=(8, 6))
sns.scatterplot(
    data=pd_sample,
    x="climate_pressure",
    y="climate_temperature",
    alpha=0.5,
    edgecolor=None
)
sns.regplot(
    data=pd_sample,
    x="climate_pressure",
    y="climate_temperature",
    scatter=False,
    color="red",
    label="Trend Line"
)
plt.title("Relationship Between Atmospheric Pressure and Temperature", fontsize=14)
plt.xlabel("Climate Pressure (hPa)")
plt.ylabel("Climate Temperature (°C)")
plt.legend()
plt.grid(alpha=0.3)
plt.tight_layout()
plt.show()

print("""
Insight (same as your original note):
- Large-scale atmospheric physics suggests lower pressure often pairs with storms/cooling,
  and high pressure with clear/warm conditions.
- If you see a positive correlation in the data, altitude bias or other confounders
  (like elevation not being modeled) may be responsible.
""")

# -------------------------------------------
# k. Stop Spark (if running as script)
# -------------------------------------------
spark.stop()


