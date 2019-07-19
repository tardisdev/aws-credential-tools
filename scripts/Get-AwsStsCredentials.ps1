<#
.SYNOPSIS
    Script to obtain temporary AWS STS credentials from an SSO IdP.
.DESCRIPTION
    Get-AwsSTSCredentials connect to a single sign-on identity provider URL supplied to the script and using an Internet Explorer COM object will authenticate a user and use the returned SAML Response in a REST call to AWS STS endpoint and obtain temporary AWS programmatic credentials to the calling user/process.
    TODO:
    Session Duration - allow user to set session duration if it is less than the SAML assertion response.
    Preselect Role - allow user to attempt to preselect a role by entering a search string (e.g. "read" for "ReadOnly" roles, or "admin" for "FullAdmin" roles)
                     then default to asking the user if search returns 0 roles.
.PARAMETER URL
    Source file for well formatted AWS credentials file.
.PARAMETER OverrideAWSRegion
    Destination file where output is to be written.
.INPUTS
    Requires URL from SSO IdP that will return the SAML Response.
.OUTPUTS
    Returns an object containing a AWS credentials: AccessKeyID, SecretAccessKey, SessionToken and Expireation.
.NOTES
  Version:        0.1.0
  Author:         Dominic P.
  Creation Date:  16/06/2019
  Purpose/Change: Initial script development.
  
.EXAMPLE
    Get-AwsSTSCreds -URL https://myssoapps.myidp.com/?appid=someappid_etc -OverrideAWSRegion "ap-southeast-2"

#>

param(
[Parameter(Position=0,Mandatory=$true,HelpMessage="Single sign-on URL from Identity Provider.")] 
[string] $URL,
[Parameter(Mandatory=$false,Position=1,HelpMessage="Override default AWS STS region.")] 
[string] $OverrideAWSRegion = "ap-southeast-2"
)

#----------------------------------------------------------[Declarations]----------------------------------------------------------

[int] $waitCount = 0 # Loop increment 
[int] $waitCountSeconds = 60 # Seconds to wait for URL to return SAML Response 
[int] $sleepCountMilliseconds = 5 # Milliseconds between URL reads for SAML Response

#-----------------------------------------------------------[Functions]------------------------------------------------------------

# TODO: Convert to functions at some stage - its a bit monolithic eh.

#-----------------------------------------------------------[Execution]------------------------------------------------------------


# Set browser size and position 10% space all around on primary screen
## TODO: DPI scalaing makes this smaller when scaling is greater than 100% scaling.
try {
    Add-Type -AssemblyName System.Windows.Forms
} catch {
    Write-Error "Error in loading Windows Forms Assembly - Internet Explorer size may be affected - continuing."
}

try {
    $myCurrentDisplay = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    $myWindowPosition = [pscustomobject]@{
        height = [int][math]::Round(($myCurrentDisplay.Height*0.8))
        width = [int][math]::Round(($myCurrentDisplay.Width*0.8))
        top = [int][math]::Round(($myCurrentDisplay.Height*0.1))
        left = [int][math]::Round(($myCurrentDisplay.Width*0.1))
    }
} catch {
    Write-Error "Error in getting or setting Primary Screen Size - Internet Explorer size may be affected - continuing."
}
# New Internet Explorer object.
try {
    $myIESession = New-Object -ComObject "InternetExplorer.Application"
} catch {
    Write-Error "Unable to open Internet Explorer - exiting."
    return
}

# Remove menu and address bar.
$myIESession.AddressBar = $false
$myIESession.MenuBar = $false

# Set IE window position and size - and make visible.
$myIESession.Left = "$($myWindowPosition.left)"
$myIESession.top = "$($myWindowPosition.top)"
$myIESession.height = "$($myWindowPosition.height)"
$myIESession.width = "$($myWindowPosition.width)"

$myIESession.Visible = $true

# Go to URL.
try {
    $myIESession.Navigate2($URL)
} catch {
    Write-Error "Error in navigating to $URL - exiting."
    return
}

# Ensure var is empty.
$myResponseFormData = ""

# Loop while user logs in, wait for the SAML Request and capture response.  
do {
        if($myIESession.LocationURL -like "*SAMLRequest*") {
            # Get SAMLResponse content from formdata.
            # TODO: selecting object [0] is a bit low tech, potential tabs make this hard - should be improved in the future.
            $myResponseFormData = $myIESession.document.forms[0].innerHTML
        }
    Start-Sleep -Milliseconds $sleepCountMilliseconds

    # Waited too long for SAML response, there is probably an error.
    if ($($sleepCountMilliseconds*$waitCount) -gt $($waitCountSeconds*1000)) {
        Write-Error "Waited $waitCountSeconds for URL $URL to return credentials, no SAML Response - exiting."
        return
    }
} while ($myResponseFormData -eq "")

# Extract SAMLResponse from full form response
# TODO: Could be more elegant, rather than string splitting convert the HTML into object.
$aadSamlResponse = $($myResponseFormData -split "`"")[5]

# Close IE Window.
try {
    $myIESession.Quit()
} catch {
    Write-Error "Error in exiting Internet Explorer, may need to kill the process later - continuing."
}

# Convert SAML Response from BASE64 to XML.
try {
    [xml] $aadSamlContentXml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($aadSamlResponse))
} catch {
    Write-Error "SAML response is not well formed XML or there is another error - exiting."
    return
}

# Extract available roles from SAML Response.
$myAvailableRoles = $($aadSamlContentXml.Response.Assertion.AttributeStatement.Attribute | Where-Object -Property "Name" -EQ "https://aws.amazon.com/SAML/Attributes/Role" | Select-Object AttributeValue).AttributeValue

# If more than 1 role is returned from IdP then ask the user to select the role.
if(($($myAvailableRoles| Measure-Object).Count) -gt 1) {

    Write-Host "The following are the roles are available to the user:"

    # Display each role to the user for selection.
    for([int]$i = 0; $i -lt $myAvailableRoles.Count; $i++) 
        {
            Write-Host "Role ID [$i]: $($myAvailableRoles[$i])"
        }

        # Continue prompting the user if response is not valid.
        do {
            try {
                [int] $userRoleID = Read-Host -Prompt "Please select Role ID to request credentials"
            } catch {} 
        } while ($userRoleID -notin 0..($myAvailableRoles.Count-1))

        # Assign selected role for use. 
        $myUserRole = $myAvailableRoles[$userRoleID]

}

# If only one role is in the SAML response then don't prompt the user.
else {
    $myUserRole = $myAvailableRoles
}

# Assign the relevant varibles for the AWS STS REST API call.
$myPrincipalArn = $($myUserRole -split ",")[1]
$myRoleArn = $($myUserRole -split ",")[0]
$myDurationSeconds = $($aadSamlContentXml.Response.Assertion.AttributeStatement.Attribute | Where-Object -Property "Name" -EQ "https://aws.amazon.com/SAML/Attributes/SessionDuration" | Select-Object AttributeValue).AttributeValue
$mySamlAssertion = $aadSamlResponse 

# Generate the AWS STS REST API URL and query - specific region for the API call can be input as parameter.
$awsStsApiEndpointUrl = "https://sts.$(if($OverrideAWSRegion){"$OverrideAWSRegion."})amazonaws.com/"
$myAwsStsApiQueryUrl = "?Version=2011-06-15"+`
            "&Action=AssumeRoleWithSAML"+`
            "&DurationSeconds=$myDurationSeconds" +`
            "&PrincipalArn=$([uri]::EscapeDataString($myPrincipalArn))" +`
            "&RoleArn=$([uri]::EscapeDataString($myRoleArn))"+`
            "&SAMLAssertion=$([uri]::EscapeDataString($mySamlAssertion))"

# Make the AWS STS REST API call and return the response.
try {
    $myStsApiResponse = $(Invoke-RestMethod ($awsStsApiEndpointUrl + $myAwsStsApiQueryUrl) -ErrorVariable irmErr).AssumeRoleWithSAMLResponse.AssumeRoleWithSAMLResult.Credentials
} catch  {
    Write-Host -ForegroundColor Red "Error in STS rest call - exiting.`nRest Response:`n $($irmErr.Message)"
    return
}

return $myStsApiResponse