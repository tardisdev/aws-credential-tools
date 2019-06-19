<#
.SYNOPSIS
    Script to update temporary AWS STS credentials from an SSO IdP.
.DESCRIPTION
    Update-AwsCredentials will parse an existing AWS Credentials or Config file and, where the AWS profile has the attribute/key "aws_sso_url" with a valid SSO url to an IdP will attempt to call Get-AWSSTSCreds and update with temporary STS credentials.
.PARAMETER InputFile
    Source file for well formatted AWS credentials file.
.PARAMETER OutputFile
    Destination file where output is to be written.
.PARAMETER BackupFirst
    Selects whether to backup the source file prior to overwriting it.
.PARAMETER OutputFormat
    Selects the output format of the detination fine (defautls to Text: same as AWS credential file format).
.PARAMETER ConsoleOnly
    Selets whether to display output to console, if true no file modification/write processes will occur.
.INPUTS
    InputFile: Source file location of AWS credentials or config file.
.OUTPUTS
    OutputFile: Detination file location for script to put new credentials.
.NOTES
  Version:        0.1.0
  Author:         Dominic P.
  Creation Date:  16/06/2019
  Purpose/Change: Initial script development.
  
.EXAMPLE
    Update-AwsCredentials -InputFile <path> -OutputFile <path> -OutputFormat [Text/Json] -BackupFirst -ConsoleOnly
#>

param(
[Parameter(Position=0,Mandatory=$false,HelpMessage="Source file parsed to find existing AWS profiles and SSO URLs associated with them. Typically %USERPROFILE%\.aws\credentials")]
[string] $InputFile = "$($ENV:USERPROFILE)\.aws\credentials",
[Parameter(Position=1,Mandatory=$false,HelpMessage="Desintation file if wanting to preserve original source file.")] 
[string] $OutputFile = $InputFile,
[Parameter(Position=2,Mandatory=$false,HelpMessage="Used to backup source file before writing to it, only condidered if source and destination file are the same.")] 
[switch] $BackupFirst,
[Parameter(Position=3,Mandatory=$false,HelpMessage="Export format of profile details, valid option are Text/Json. If selecting format other than Text consider not overwriting source file.")] 
[ValidateSet("Text","Json")] [string] $OutputFormat = "Text",
[Parameter(Position=4,Mandatory=$false,HelpMessage="Used to select output to console only, all file write operations will be skipped.")] 
[switch] $ConsoleOnly
)

#----------------------------------------------------------[Declarations]----------------------------------------------------------

[string] $keyPreviousValue = "previousValue"
[string] $keyNewValue= "NewValue"

[string] $keyAwsAccessKeyId = "aws_access_key_id"
[string] $keyAwsSectretAccessKey = "aws_secret_access_key"
[string] $keyAwsSessionToken = "aws_session_token"
[string] $keyAwsSsoUrl = "aws_sso_url"
[string] $keyAwsCredsExpiry = "aws_sts_creds_expiry"
[string[]] $keysToFind = ($keyAwsAccessKeyId,$keyAwsSectretAccessKey,$keyAwsSessionToken,$keyAwsSsoUrl,$keyAwsCredsExpiry)

[string] $keyRemainingProfileLines = "RemainingProfileLines"
[string] $outputTimeFormat = "dd/MM/yyyyTHH:mm:ss"


# Null certain vars that may cause incorrect results when persisted between runs.
# TODO: Maybe dispose instead, but helpful for debugging.
$profileName = ""
$awsProfileMetadata = $null
$myAwsStsCreds = $null
[string[]]$outFileContent = $null

#-----------------------------------------------------------[Functions]------------------------------------------------------------

# TODO: Convert to functions at some stage - its a bit monolithic eh.


#-----------------------------------------------------------[Execution]------------------------------------------------------------

# Import input file and write contents to array.
try {
    $text = Get-Content $InputFile
    Write-Host "Successfully imported InputFile"
} catch {
    Write-Error "Error reading InputFile from location - exiting."
    return
}

# Process input file line by line to find profiles, keys and their respective values.
try {
    foreach ($line in $text) {
        if($line -like "# SCRIPTED UPDATE #*") {
            continue
        } 

        # Match profile pattern [SomeAWSProfile] - create root "Profile" node in hashtable.
        # Key/value pairs succeeding this profile belong to it.
        if($line -match "\[.*?\]") {
            $profileName = $line -Replace '^.*\[([^\[]+)]$', '$1'
            $awsProfileMetadata = $awsProfileMetadata + @{"$profileName" = @{}}
            Write-Host "Found AWS profile: $profileName"
            continue
            
        }
        
        # Break down lines containing key/value seperator ("=").
        # TODO: Persist comments after value.
        #       Example: aws_access_key_id = AAAAAAAAAAAAAAAAAAAA # This comment will currently be lost...
        if ($line.ToCharArray() -contains "=") {
            $currentLine = $line.Split("=")
            $key = $currentLine[0].Trim()
            $value = $($line.Substring($line.IndexOf("=")+1).Trim())
            if ($value.ToCharArray() -contains " ") {
                $value = $value.Split(" ")[0].Trim()
            }

            # If key found is a interesting key it's value will be captured.
            # Keys found not to be interesting will be picked up and added to "remaining lines" node in the hashtable.
            if ($keysToFind -contains $key) { 
                $awsProfileMetadata.$profileName += @{$key = @{$keyPreviousValue = $value}}
                Write-Verbose "Found $key key $profile profile, with value $value"
                continue
            }
        }

        # Lines preceeding any profile will be persisted between files.
        if($profileName -eq "") {
            $outFileContent += $line
            continue
        }

        # Non-interesting lines (comments, non important key/value pairs, anything else) will be persisted as best as possible between files.
        else {
            if ($awsProfileMetadata.$profileName.$keyRemainingProfileLines) {
                $awsProfileMetadata.$profileName.$keyRemainingProfileLines += @{$line.ReadCount = $line}
            }
            else {
                $awsProfileMetadata.$profileName += @{$keyRemainingProfileLines = @{$line.ReadCount = $line}}
            }
        }
    }
} catch {
    Write-Error "Error reading Inputfile contents - exiting."
    return
}

Write-Host "Successfully completed reading InputFile."

ForEach ($awsProfile in $awsProfileMetadata.Keys) { 

    ForEach ($key in $keysToFind) {

        # If AWS Profile contains a record that matches an interesting key
        if($awsProfileMetadata.$awsProfile.$key) {

            # If the interesting key within the AWS profile has a value of not null then copy the contents to the new key,
            # this may be overwritten by the STS response, but if not then the original value will be written to the new file.
            if ($awsProfileMetadata.$awsProfile.$key.$keyPreviousValue) {

                $awsProfileMetadata.$awsProfile.$key.Add($keyNewValue,$awsProfileMetadata.$awsProfile.$key.$keyPreviousValue)
            }
        }

        # If the AWS Profile doesn't contain a record that matches an interesting key then create it as it may be a required key for the STS response.
        else {
            $awsProfileMetadata.$awsProfile.Add($key, @{$keyNewValue = $null})
        }

    }

    # If the profile has an IdP SAML URL defined then pass to Get-AwsSTSCreds.ps1 for processing.
    if ($awsProfileMetadata.$awsProfile.$keyAwsSsoUrl.$keyPreviousValue) {

        try {
            # Hand off to other script.
            Write-Host "Attempting to get temp AWS STS credentials for $awsProfile. You may be prompted to authenticate to your Identity Provider."
            $myAwsStsCreds = .\Get-AwsSTSCredentials.ps1 $awsProfileMetadata.$awsProfile.$keyAwsSsoUrl.$keyPreviousValue
        } catch {
            Write-Error "Error getting AWS STS credentials for profile $awsProfile in Get-AwsSTSCreds script - exiting."
            return
        }

        # Upon response from Get-AwsSTSCreds.ps1 add new STS creds into hashtale.
        try {
            $awsProfileMetadata.$awsProfile.$keyAwsSessionToken.$keyNewValue = $myAwsStsCreds.SessionToken
            $awsProfileMetadata.$awsProfile.$keyAwsAccessKeyId.$keyNewValue = $myAwsStsCreds.AccessKeyId
            $awsProfileMetadata.$awsProfile.$keyAwsSectretAccessKey.$keyNewValue= $myAwsStsCreds.SecretAccessKey
            $awsProfileMetadata.$awsProfile.$keyAwsCredsExpiry.$keyNewValue = [datetime]::SpecifyKind($myAwsStsCreds.Expiration,"UTC").ToString($outputTimeFormat)
        } catch {
            Write-Error "Error in STS response for $awsProfile - this profile may not work correctly. Continuing to next profile..."
        }
    }

    # Add AWS Profile contents to output var for writing to new file.
    $outFileContent += "[$awsProfile]"
    # Write interesting keys and their values into their profile.
    ForEach ($key in $keysToFind) {
        if ($awsProfileMetadata.$awsProfile.$key.$keyNewValue) {
            $outFileContent += "{0} = {1}" -f $key, $awsProfileMetadata.$awsProfile.$key.$keyNewValue
        }
    }

    # Write non-interesting lines into their profile.
    if ($awsProfileMetadata.$awsProfile.$keyRemainingProfileLines) {
        ForEach ($key in $($awsProfileMetadata.$awsProfile.RemainingProfileLines.Keys | Sort-Object)) {
            $outFileContent += $awsProfileMetadata.$awsProfile.$keyRemainingProfileLines.$key
        }
    }
    
    Write-Host "Successfully obtained AWS credentials for $awsProfile."
 
}

# Modify output to be Json only, this will strip all comments (and will not be re-importable by the script).
# TODO: Add other output formats - CSV, Direct to Environment Variables, XML
switch ($OutputFormat) {
    "Json" {
        $outFileContent = $awsProfileMetadata | ConvertTo-Json
    }
}

# Write all contents to console.
if($ConsoleOnly) {
    $outFileContent
}

# Write contents to file.
else {

    # Make a copy of the input file if requested - postpend date and time plus .bak to the filename.
    if ($BackupFirst) {
        if ($InputFile -eq $OutputFile) {
            try {
                Copy-Item -Path $InputFile -Destination $($InputFile + $(Get-Date -Format "_yyyy-MM-dd_HHmm-ss") + ".bak")
            } catch {
                Write-Error "Error unable to backup InputFile - exiting."
                return
            }
            Write-Host "Backup successfully taken of source file."
        }
        else {
            Write-Host "Source and destination file are not the same, backup not created."
        }
    }
    
    try {
        # Write contents to output file.
        # TODO: If input file name and output file name match, and the output format is not text then prompt the user to ensure thats what they want, give them a chance to specify different destination here.
        Set-Content -Path $OutputFile -Value "# SCRIPTED UPDATE # This file has been automatically modifed by Update-AWSCredentials script: $(Get-Date -Format $OutputTimeFormat)",$outFileContent
        Write-Host "Successfully written new AWS credentials to destination file."
    } catch {
        Write-Error "Error writing to $OutputFile - exiting."
        return
    }
}

