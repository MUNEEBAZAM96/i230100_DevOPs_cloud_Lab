# CV on AWS — i230100

Muneeb Ur Rehman, roll number i230100. Region for every resource: **eu-north-1**.

| Resource | Name |
| --- | --- |
| S3 bucket | `cv-i230100` |
| EC2 instance | `cv-ec2-i230100` |
| EC2 role | `cv-ec2-role-i230100` |
| Lambda function | `cv-func-i230100` |
| Lambda role | `cv-lambda-role-i230100` |

The bucket, the instance, the function, and both roles are tagged `Owner=i230100` and `Course=cloud`.

## How a request reaches the CV

```
                         +-----------------------------+
                         | Private S3 bucket           |
                         | cv-i230100                  |
                         | site/index.html             |
                         | site/style.css              |
                         | site/cv.pdf                 |
                         | Block Public Access: all on |
                         +-------------+---------------+
                                       |
                 GetObject + ListBucket|prefix site/   | GetObject only
                                       |               |
              +------------------------+               +------------------+
              |                                                         |
              v                                                         v
   +----------+-----------+                              +--------------+--------------+
   | EC2 cv-ec2-i230100   |                              | Lambda cv-func-i230100     |
   | Amazon Linux 2023    |                              | Python, function URL NONE  |
   | httpd on port 80     |                              | stamps "Lambda" + name     |
   | role cv-ec2-role-... |                              | role cv-lambda-role-...    |
   +----------+-----------+                              +--------------+--------------+
              ^ HTTP :80                                                ^ HTTPS
              |                                                         |
              +--------------------------+------------------------------+
                                         |
                                      Browser

   Direct S3 URL for site/index.html  -->  Access Denied
```

A browser request to the EC2 address is served by httpd from the copy of `site/` that `sync-cv.sh` downloaded and stamped with the word EC2 and the instance ID. A browser request to the Lambda function URL runs the function, which reads the same private objects with its role and stamps the page with the word Lambda and the function name.

## Addresses

EC2: http://13.61.190.218/

Lambda: https://mpihm73jk5ynszsboz4zbduhay0drspl.lambda-url.eu-north-1.on.aws/

Direct S3 object (must stay denied): `https://cv-i230100.s3.eu-north-1.amazonaws.com/site/index.html`

## Access denied from the instance

The EC2 role can read `site/` and list that prefix. It cannot delete or overwrite an object. This is the output of `aws s3 rm s3://cv-i230100/site/index.html --region eu-north-1` from the instance shell:

```
delete failed: s3://cv-i230100/site/index.html An error occurred (AccessDenied) when calling the DeleteObject operation: User: arn:aws:sts::487694860646:assumed-role/cv-ec2-role-i230100/i-0a95a07241d04a7ab is not authorized to perform: s3:DeleteObject on resource: "arn:aws:s3:::cv-i230100/site/index.html" because no identity-based policy allows the s3:DeleteObject action
```

## Last 10 lines of /var/log/cv-sync.log

`ec2/sync-cv.sh` runs once from user data and then from a systemd timer every 5 minutes (`OnUnitActiveSec=5min`).

```
2026-10-22T22:18:41Z OK sync worked
2026-10-22T22:19:09Z OK sync worked
2026-10-22T22:24:13Z OK sync worked
```

## Written answers

1. The instance and the function use roles so AWS can give them short-lived credentials through the metadata service and the Lambda runtime. Those credentials only allow the reads this lab needs, and they expire on their own. An access key in user data would be a long-lived secret in a script that this public repository also contains. Anyone who can read the instance user data could copy that key and call AWS as me from anywhere. A leaked key that was allowed to write could delete the CV, and I would have to find and deactivate it by hand.

2. They see Access Denied from S3, not the CV page. All four Block Public Access settings are on, so S3 refuses an anonymous GetObject for `site/index.html`. There is no bucket policy and no ACL that grants access to everyone. Only the two IAM roles are allowed to read those objects.

3. The function URL uses auth type NONE, and its resource policy allows `lambda:InvokeFunctionUrl` for principal `*` when the auth type is NONE. Since October 2025 the console also allows `lambda:InvokeFunction` for `*` with the condition that the call came through the function URL. That only lets a visitor run this one function. It is acceptable because the function reads the three CV files and returns them, while the bucket itself stays private. The same public permission on the bucket would let anyone read the objects directly and would ignore the roles.

4. When nobody visits, the EC2 path still uses the hours the t3.micro is running, which Free Tier covers up to its monthly limit, plus a few hundred kilobytes of S3 storage. Lambda costs nothing for compute until a request arrives. If traffic grows a hundred times, Lambda runs more copies and the bill follows the number of requests and how long they run. The single EC2 instance does not grow by itself, so it can get slow while its hourly price stays the same until the instance type is changed. S3 remains the same private store either way.

5. Deleting the instance removes its public address, the web server, and the sync log that lived on that disk. The security group remains until it is deleted separately, but nothing is listening on it. The private bucket, the three CV files, both IAM roles, and the Lambda function URL are still there, so the CV stays on the internet through Lambda. A new instance with the same role and user data can serve the EC2 path again, because the files were never kept only on the instance.

## What I adapted

The IMDSv2 token request follows the EC2 user guide. The S3 prefix condition follows the IAM examples for `s3:ListBucket`. The function URL permissions follow the Lambda function URL docs, including the extra `lambda:InvokeFunction` statement required for new function URLs. Amazon Linux 2023 does not install cron, so the schedule is a systemd timer, as described in the AL2023 release notes. The three object ARNs are listed by name so neither role uses a wildcard action or a wildcard resource. The managed policy `AWSLambdaBasicExecutionRole` is the logging exception the lab allows. This repository was prepared in Cursor.

## After marking

Delete the instance, the function and its log group, both roles and the instance profile, the bucket including every version, and the security group. Check eu-north-1. Do not leave an Elastic IP, a NAT gateway, or a load balancer, because none were created.
