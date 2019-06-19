<<<<<<< HEAD
# aws-credential-tools
A collection of scripts and modules that help with AWS programmatic credentials.
=======
# AWS Credential Tools

A collection of scripts and modules that help with AWS programmatic credentials.

_Note: these tools are in development and breaking changes may occur with any update_ 

## The Words

### The What

AWS Credential Tools is collection of PowerShell tools that assist with obtaining, storing and renewing AWS credentials using SAML Identity Providers (IdP) like Azure AD or Active Directory Federation Services (ADFS).

_Note: Other IdP's may work but these have not been tested._

### The Why

While these scripts are quite generic and can be applied in many ways they were developed to meet a not so unique use case.

#### The background

While working with a large government department deploying cloud native solutions there was a requirement to use a SAML Federated Identity Provider (in this case Azure AD) to authenticate users to multiple AWS accounts and roles.

Both technologies allow for this quite seamlessly, that is, if all your interaction is with the AWS console (web UI).  However this does present challenges for programmatic access when using tools like AWS CLI, AWS Tools for Windows PowerShell, Boto3, Terraform and other command line services.

While some of these tools have built-in methods to perform SAML authentication to some IdP's (like Azure AD, Google etc.) there is not much consistency around the multi-factor authentication (MFA) systems and how they are handled - additionally tools like Terraform do not have functions to interact with AWS Security Token Service (STS) to obtain temporary credentials.

Another alternative, developers and admins have an IAM user account with a set or two of access keys will achieve a similar result.  However, it does break the pattern of *not* having any IAM users eliminating much of the benefit of using an IdP for federated authentication, and with the overhead of having to check and remove those IAM users when they leave.

#### The use-case

>The ability for a user with a *really* locked down SoE to use command line and automation tools to interact with AWS services.

>Working only common Windows OS components (PowerShell, Internet Explore) develop a mechanism for users to authenticate with Azure AD (with MFA) to interact with those services programmatically.

While working with this large government department we had a very locked down SoE that only allowed for the install of very few *approved* applications, as well as using Azure AD with MFA for authentication.

We needed a mechanism to be able to provide programmatic access for our users without the need to install any additional applications on top of the SoE.  Users had Azure AD Federated Accounts so using this was a no-brainer.

While there is currently a number of solutions to solve the SMAL to AWS STS solutions developed in Node.js or python using Chromium or Selenium - neither solution available on the SoE.  The solution with the parts available; PowerShell for scripting and Internet Explorer COM Object for programatic browser interaction.

## The codes

### Get-AwsStsCredentials.ps1

Tested on the following versions:

* PowerShell
  * 5.1
* Internet Explorer
  * 11

#### Basic usage

`$awsStsCreds = Get-AwsStsCredentials -URL "https://myssoapps.myidp.com/?appid=someappid_etc" -OverrideAWSRegion "ap-southeast-2" `

#### Returned

The script will return an PSObject with the following members:

~~~ PowerShell
{  
    "AccessKeyId": "string"
    "SecretAccessKey": "string"
    "SessionToken": "string"
    "Expiration": "1970-01-01T00:00:00Z"
}
~~~

#### Parameters

##### URL

_Mandatory: True_
>Single sign-on URL from Identity Provider.  
>An example of an Azure AD Enterprise Application SAML SSO URL:  
https://myapps.microsoft.com/signin/MyAWSApplication/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx?tenantId=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

##### OverrideAWSRegion

_Mandatory: False_
>Override default AWS STS region.  
>This will add in the AWS Region into the AWS STS API call. For example passing the following region "ap-southeast-2" will modify the AWS STS API URL:  
From: `https://sts.amazonaws.com/`  
To: `https://sts.ap-southeast-2.amazonaws.com/`

#### The detail

This scrip will perform the following:

1. Open an Internet Explorer COM Object instance.
2. Navigate to the URL passed through to the script and present the Internet Explorer window to the user.
3. Prompt the user to authenticate with their IdP in the browser instance (with MFA if applicable).
4. Once the IdP returns the SAML Response the script will intercept it and close the Internet Explorer browser window.
5. If there are multiple AWS roles available the script will prompt the user to select their preferred role.
6. Once the role is selected (or if there is only one role to select from) the script will make an AWS STS REST call and return the result.

#### The bits not finished

* Functions
  * Needs to be refactored into a few functions and a smaller execution block to breakdown reusable nuggets of code.
* DPI Scaling for IE Window
  * Currently IE will open with a 10% gap on all sides, when DPI scaling is in use this does not occur rather the window is smaller when scaling greater than 100%
* SAMLResponse
  * Currently explicitly looking for "SAMLRequest" in the IE Location URL, this should be paramiterised and then may enable more IdP's.
* Control When IE is visible
  * IE only needs to be called when input is required - when authentication to the IdP is cached the user does not need to see the window.
* Remove Internet Explorer
  * Look at moving the web calls to Invoke-WebRequest.
* Cleanup splitting the SAML response.
  * Currently splitting on an " delimiter where the string is a well formed HTML tag.
* Simple Role Selection
  * A parameter to either pass a string to match within role ARN or auto-select first role when multiple roles are present.

### Update-AwsCredentials.ps1

Tested on the following versions:

* PowerShell
  * 5.1

#### Basic Usage

Run with default parameters:

`Update-AwsCredentials`

Run with all parameters:

`Update-AwsCredentials -InputFile <path> -OutputFile <path> -OutputFormat [Text/Json] -BackupFirst -ConsoleOnly`

#### Returned

The script is capable of returning either TOML or Json of the hashtable object created by the script.  The object will contain both old-credentials and newly acquired credentials as applicable and may be directed to the console, but will be written to file by default.

#### Parameters

##### InputFile

_Mandatory: False_  
_Default:_ `$($ENV:USERPROFILE)\.aws\credentials`  
_Description:_ Path to Source File.  
Input file is expected to be in well formed TOML file format. e.g:

~~~ TOML
[aws profile]  
aws_access_key_id = AAAAAAAAAAAAAAAAAAAA
aws_secret_access_key = abc/defghijklm/nopqrstuvw/xyz/1234567890

[aws sso profile]  
aws_access_key_id = AAAAAAAAAAAAAAAAAAAA
aws_secret_access_key = abc/defghijklm/nopqrstuvw/xyz/1234567890
aws_sso_url = https://myssoapps.myidp.com/?appid=someappid_etc
~~~

_Note: The only field required when enabling a SSO profile is the `aws_sso_url` key, the remaining fields will be automatically generated by the script. Any profile not containing `aws_sso_url` will remain unchanged._

##### OutputFile

_Mandatory: False_  
_Default:_ `$InputFile`  
_Description:_ Path to Destination File.  

##### OutputFormat

_Mandatory: False_  
_Default:_ Text
_Options:_ Text | Json  
_Description:_ Format in which to output the configuration.  

##### BackupFirst

_Mandatory: False_  
_Default:_ False
_Description:_ Switch parameter to backup InputFile before write operations.

_Note: Backup file name will append `_yyyy-MM-dd_HHmm-ss.bak` to source file then write._

##### ConsoleOnly

_Mandatory: False_  
_Default:_ False
_Description:_ Switch parameter to write output only to the console and not perform any file write operations.

#### The detail

The scrip will perform the following:

1. Import source credential file.
2. Parse TOML and generate a hashtable of "interesting" key/value pairs within each AWS profile.
3. Capture all other lines and "non-interesting" key/value pairs under each profile.
4. Iterate through each profile and do the following:
   1. Write all "current" credential values to "new" credential value fields (for writing non-updated profiles).
   2. For each profile containing an `aws_sso_url` key pass the value to Get-AwsStsCredentials.ps1
   3. Write response into "new" credential values within the hashtable.
5. Generate output (either TOML or Json)
6. Backup existing credentials file if requested.
7. Write output to console or file as requested.

#### The bits not finished

* Functions
  * Needs to be refactored into a few functions and a smaller execution block to breakdown reusable nuggets of code.
* Other formats
  * Add other input and output formats.
* Prompt user if format change on write
  * As the script only parses TOML, if the input and output files are the same and the chosen output format is not TOML ask the user "are you sure?".
* Dispose objects before exit
  * Currently all objects are Null'd when declared, would prefer to dispose but they are useful when debugging.
* Parse, store and process comments better.
  
When processing the following:

``` TOML
    [AWS_Profile]
    # This is a comment pertaining to the non-SSO profile.
    aws_access_key_id = AAAAAAAAAAAAAAAAAAAA # this is a comment that relates to the key
    aws_secret_access_key = abc/defghijklm/nopqrstuvw/xyz/1234567890

    [AWS_SSO_Profile]
    # This is a comment pertaining to the SSO profile.
    aws_access_key_id = AAAAAAAAAAAAAAAAAAAA # this is a comment that relates to the key
    aws_secret_access_key = abc/defghijklm/nopqrstuvw/xyz/1234567890
    aws_sso_url = https://myssoapps.myidp.com/?appid=someappid_etc
```

The output will look like the following:

``` TOML
    [AWS_Profile]
    # This is a comment pertaining to the non-SSO profile.
    aws_access_key_id = AAAAAAAAAAAAAAAAAAAA
    aws_secret_access_key = abc/defghijklm/nopqrstuvw/xyz/1234567890

    [AWS_SSO_Profile]
    aws_access_key_id = AAAAAAAAABBBBBBBBBBB
    aws_secret_access_key = 123/4567890abcdef/hijklmnopqrstuvwxyzABC
    aws_session_token = ReallyLongAWSSTSTokenThatGoesOnForever..butThenFinallyEnds==
    aws_sso_url = https://myssoapps.myidp.com/?appid=someappid_etc
    aws_sts_creds_expiry = <date>T<time>
    # This is a comment pertaining to the profile.

```

_Note the absense of comments after the `aws_access_key_id` values and the movement of the `[AWS_SSO_Profile]` comment to the bottom of the profile._

It goes without saying... But...  

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
>>>>>>> Inital Commit
