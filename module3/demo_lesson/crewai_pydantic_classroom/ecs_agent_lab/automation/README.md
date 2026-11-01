Troubleshooting and Lessons Learned

During the initial manual deployment of the ECS Fargate classroom lab, several issues were encountered and resolved. These findings informed the design of the automation scripts.

1. AWS CLI Architecture Mismatch

Error:

/usr/local/bin/aws: Bad CPU type in executable
ERROR: Unable to authenticate with AWS.

Cause:

The AWS CLI executable at /usr/local/bin/aws was built for an incompatible CPU architecture.

The development machine uses Apple Silicon (arm64), but the executable was identified as an x86_64 binary.

Diagnosis:

which -a aws
file /usr/local/bin/aws
uname -m

Resolution:

Updated the AWS CLI installation so that the executable matched the host architecture.

Verification:

aws --version
aws sts get-caller-identity

Both commands executed successfully.

Lesson learned:

Preflight checks should validate that dependencies are executable, not simply confirm that they exist.

⸻

2. ECS Task Definition Registration Failed

Error:

ClientException: Role is not valid

Investigation:

Verified that the ECS execution role and task role existed:

aws iam get-role \
  --role-name ecsAgentClassroomExecutionRole
aws iam get-role \
  --role-name ecsAgentClassroomTaskRole

Confirmed that both roles trusted the ECS task service principal:

ecs-tasks.amazonaws.com

Also verified the AWS account using:

aws sts get-caller-identity

Resolution:

Retrieved the actual IAM role ARNs and ensured that the generated task definition referenced the correct values.

export EXECUTION_ROLE_ARN=$(aws iam get-role \
  --role-name ecsAgentClassroomExecutionRole \
  --query 'Role.Arn' \
  --output text)
export TASK_ROLE_ARN=$(aws iam get-role \
  --role-name ecsAgentClassroomTaskRole \
  --query 'Role.Arn' \
  --output text)

The task definition was subsequently registered successfully.

Lesson learned:

IAM role existence, trust policies, role permissions, and task-definition references are separate concerns.

When troubleshooting ECS task registration, verify each independently.

⸻

3. IAM Policy Simulation Failed

Error:

InvalidInput: ResourceNames are not in a valid ARN format

Cause:

The IAM policy simulation command received incorrectly formatted resource ARNs.

Resolution:

Reviewed the exported IAM role ARN variables and corrected the values before proceeding.

Lesson learned:

Environment variables containing AWS resource identifiers should be inspected before they are used in API requests.

For example:

printf '%s\n' "$EXECUTION_ROLE_ARN"
printf '%s\n' "$TASK_ROLE_ARN"

This helps identify malformed ARNs and incorrect variable expansion.

⸻

4. ECS Exec Failed Because Session Manager Plugin Was Missing

Error:

SessionManagerPlugin is not found

Cause:

Although AWS CLI v2 was installed, the AWS Systems Manager Session Manager plugin was not available.

ECS Exec requires this plugin on the client machine.

Resolution:

Installed the macOS ARM64 Session Manager plugin.

Verification:

session-manager-plugin

The command confirmed successful installation.

Retried:

aws ecs execute-command \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER" \
  --task "$TASK_ARN" \
  --container security-analyst \
  --interactive \
  --command "/bin/sh"

The interactive session started successfully.

Lesson learned:

AWS CLI installation alone does not guarantee that ECS Exec is operational.

The Session Manager plugin, ECS Exec configuration, IAM permissions, and network connectivity must all be considered.

⸻

5. ECS Task Architecture Compatibility

Challenge:

The Docker image was built on an Apple Silicon machine using ARM64.

AWS Fargate must run the image using a compatible CPU architecture.

Resolution:

Configured the ECS task definition with:

{
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  }
}

Verification:

The registered task definition reported:

Status: ACTIVE
CPU Architecture: ARM64
Operating System: LINUX

The Fargate task subsequently reached RUNNING.

Lesson learned:

Container portability does not eliminate CPU architecture compatibility requirements.

The container image architecture and ECS task runtime architecture must match.

⸻

6. Understanding ECS Task Lifecycle

Observation:

The interactive ECS task remained running because its container command was:

sleep infinity

The one-off validation task exited after executing:

python security_analyst.py --validate-only

Explanation:

ECS tasks have different lifecycle expectations depending on the workload.

An interactive troubleshooting task can remain running until explicitly stopped.

A one-off task can complete its work and transition to STOPPED without indicating an application failure.

For continuously running applications, an ECS service can maintain the configured desired task count by replacing stopped tasks.

Lesson learned:

A task entering STOPPED is not automatically evidence of a failure.

Engineers must inspect the task’s exit code, stop reason, logs, and intended workload behavior.

⸻

7. CloudWatch Logs Validation

Challenge:

The interactive container initially produced no application output in CloudWatch because its default command was:

sleep infinity

Resolution:

Launched a separate ECS task with a command override:

python security_analyst.py --validate-only

Inspected the logs using:

aws logs tail /ecs/agent-classroom \
  --region "$AWS_REGION" \
  --since 1h

Result:

CloudWatch displayed:

Input schema valid: sg-classroom-example

The output also included the expected synthetic security finding:

CLASSROOM-001

Lesson learned:

CloudWatch Logs provide a useful noninteractive validation method without granting students shell access to running containers.

⸻

Automation Improvements Identified

The manual deployment revealed several opportunities to improve reliability.

Future automation should:

1. Validate required dependencies and executable architecture.
2. Confirm AWS authentication and account identity.
3. Validate Docker availability.
4. Verify IAM role existence and required permissions.
5. Validate container image architecture.
6. Confirm ECS task-definition compatibility.
7. Wait for ECS tasks to reach their expected lifecycle state.
8. Capture task ARNs instead of relying on manually copied identifiers.
9. Inspect CloudWatch Logs for validation results.
10. Provide explicit cleanup commands to prevent unnecessary AWS charges.

Current Automation Status

The manual ECS Fargate deployment and validation were completed successfully.

The deployment automation currently implements the initial environment preflight checks.

Infrastructure provisioning, automated validation, and cleanup are planned improvements.

The original classroom runbook remains the authoritative reference for the lab’s required deployment sequence.