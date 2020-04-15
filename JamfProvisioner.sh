#!/bin/sh

#####################################################################
#                           # JAMF PROVISIONER #
#                           ####################
# This script is designed to be run once on an admin computer
# to set up an entire re-provisioning process for your macOS Catalina
# and later machines. When completed it will set up a process within
# Jamf Pro that will automatically stage a copy of the latest
# "Install macOS" app onto your computers in a hidden location
# so that you easily upgrade machines or quickly erase and install
# a fresh new copy of macOS onto a machine. Which is great for 
# turnover of devices.
#
# Traditional provisioning methods involve booting a computer into
# Recovery, reformatting the hard drive, and installing
# a new macOS from Internet Recovery or USB.
# This process tends to be a bit involved and time consuming, however.
# This script will, instead, make it so once you need to turnover a machine
# You can simply log into Self Service (Preferably scoped just to the IT dept)
# And click a button and in 20 minutes the machine will be back at the setup
# assistant on the latest macOS.
#
###############
# HOW IT WORKS
###############
#
# Here is a list of what this script will create in your Jamf Pro:
#
# * An Extension Attribute that reports what version of the "Install macOS" 
#		app is staged on each computer
# * A "Provisioning" Category that all of the objects can be assigned to
# * A script that Erases any current versions of the "Install macOS" app in  
# 		/Applications when a new version is available to be downloaded
# * A script that moves the newly downloaded "Install macOS" app to the 
#		/private/var directory and compresses it to a zip archive
# * A script that will be invoked manually from Self Service to run an 
#		"EraseInstall" using the staged "Install macOS" app
# * A Smart computer group to identify computers with the latest version of the 
#		"Install macOS" app using the extension attribute created earlier
# * A Smart computer group that will check if computers DON'T have the latest version
#		staged AND are on at least 10.15 or later
# * A Policy deploying the first script and a Files and Processes payload
#		to download the latest "Install macOS" app scoped to computers 
#		that don't have the latest version of the app staged and also triggers the next 
#		policy immediately
# * A policy to deploy the second script that will move the newly downloaded
#		"Install macOS" app to the /private/var location
# * A policy to run the Eraseinstall script from Self Service, unscoped
#		so you can decide who should have access to do this task
#
# So this is a LOT of things to be created, right? What is it all doing?
# Well it's set up in such a way so that it's almost completely self sufficient.
# The extension attribute will report what version of the "Install macOS" app
# is currently staged on each device and in the smart group you just need to enter
# what the latest released version of macOS is. For instance, once 10.15.4 drops
# you can go into the smart group and enter 10.15.4 into the value and then the computers
# will all fall into scope of the first policy that will erase the older version
# and download the latest version released by Apple, stage it in the /private/var folder
# and make it ready for when you want/need to do an Erase-install. The process will not
# run again unless a computer reports, via that extension attribute, a value that doesn't
# match what you've set in the smart group. So the only thing you need to actually touch
# going forward is the smart group when you're ready to stage the latest version.
#
# NOTE: This process only works for the LATEST version of macOS. As it uses the 
# softwareupdate binary to fetch the app and the binary can only grab the latest version of
# each major OS.
#
#################
# AUTHENTICATION
#################
#
# This script will prompt you to enter the username and password of an admin in your
# Jamf Pro server so that it can make the necessary API calls to create all of the
# provisioner objects needed for this workflow. While a full access admin will work
# it is recommended for security reasons to use an account with the least amount of 
# privileges. The account you use must have at LEAST the following prvileges:
#
# READ on Jamf Pro User Accounts and Groups (This will just be used to verify your account's permissions)
# READ on Sites
# CREATE/READ on Categories
# CREATE/DELETE on Computer Extension Attributes
# CREATE/DELETE on Scripts
# CREATE/READ/DELETE on Smart Computer Groups
# CREATE/UPDATE/DELETE on Policies
#
###############
# DECONSRUCTOR
###############
#
# At the end, the script will ask you if you would like a "Deconstructor" script 
# created for you. This is good for demo or test environments. What it will do is 
# save the ID numbers of all of the objects that are created and it will write a script
# out to your desktop so that if you want to delete all of the things it created
# then you can just run that script.
#
#######################################################################################
#
#	MIT License
#
#	Copyright (c) 2020 Jamf Open Source Community
#
#	Permission is hereby granted, free of charge, to any person obtaining a copy
#	of this software and associated documentation files (the "Software"), to deal
#	in the Software without restriction, including without limitation the rights
#	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#	copies of the Software, and to permit persons to whom the Software is
#	furnished to do so, subject to the following conditions:
#
#	The above copyright notice and this permission notice shall be included in all
#	copies or substantial portions of the Software.
#
#	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#	SOFTWARE.
#
###########################################################################################

###################################################
# ESTABLISH STARTING VARIABLES FUNCTIONS AND ARRAYS
###################################################

#Do not manually edit these
version="Jamf Provisioner 1.0"
logPath=~/Desktop/JamfProvisionerLogs.txt
siteList=""
latestMacOS=$(curl -s https://developer.apple.com/news/releases/rss/releases.rss | grep "<title>macOS" | grep -v -e "beta" | grep -m1 "" | awk '{print $3}')
siteArray=()
scriptIDarray=()
policyIDarray=()
computerGroupIDarray=()

#Function for rolling back everything created if there's an error during the creation process
function rollback() {
	echo $(date) "Rolling back everything that has been created so far..." >> $logPath
	#Get the sizes of all the arrays
	scriptSize=${#scriptIDarray[@]}
	policySize=${#policyIDarray[@]}
	computerGroupSize=${#computerGroupIDarray[@]}
	
	#Start by deleting the policies if any were created
	if [[ "$policySize" -gt 0 ]]; then
		policyIndex=$(($policySize-1))
		for i in $(seq 0 $policyIndex); do
			curl -su $adminUser:$adminPass $jamfProURL/JSSResource/policies/id/${policyIDarray[$i]} -X DELETE
			echo $(date) "Policy with ID ${policyIDarray[$i]} deleted... " >> $logPath
			done
			fi
	
	#Next delete the smart groups if they were created
	if [[ "$computerGroupSize" -gt 0 ]]; then
		computerGroupIndex=$(($computerGroupSize-1))
		for i in $(seq $computerGroupIndex 0); do
			curl -su $adminUser:$adminPass $jamfProURL/JSSResource/computergroups/id/${computerGroupIDarray[$i]} -X DELETE
			echo $(date) "Computer Group with ID ${computerGroupIDarray[$i]} deleted... " >> $logPath
			done
			fi
				
	#Next delete the scripts if they were created
	if [[ "$scriptSize" -gt 0 ]]; then
		scriptIndex=$(($scriptSize-1))
		for i in $(seq 0 $scriptIndex); do
			curl -su $adminUser:$adminPass $jamfProURL/JSSResource/scripts/id/${scriptIDarray[$i]} -X DELETE
			echo $(date) "Script with ID ${scriptIDarray[$i]} deleted... " >> $logPath
			done
			fi
	
	#Wait a few seconds to delete extension attribute so it can catch up
	sleep 5
	
	#Finally, if the extension attribute was created, delete it
	if [[ ! -z $eaID ]]; then
		curl -su $adminUser:$adminPass $jamfProURL/JSSResource/computerextensionattributes/id/$eaID -X DELETE
		echo $(date) "Extension attribute deleted...." >> $logPath
		fi
	pkill jamfHelper
}

#Function for new POSTs via the API
function provisionerPost() {
	endpoint="$1"
	xml="$2"
	
	case $endpoint in
		"computerextensionattributes")
		object="computer_extension_attribute"
		;;
		"scripts")
		object="script"
		;;
		"policies")
		object="policy"
		;;
		"computergroups")
		object="computer_group"
		;;
		"categories")
		object="category"
		;;
	esac
	echo $(date) "Creating $object..." >> $logPath
	postID=$(curl -su $adminUser:$adminPass $jamfProURL/JSSResource/$endpoint/id/0 -H "Content-type: text/xml" -X POST -d "$xml")
	postIDFormatted=$(echo $postID | xmllint --xpath "/$object/id/text()" -)
	
	#Check for errors in post
	if ! [[ "$postIDFormatted" =~ ^[0-9]+$ ]]; then
			echo $(date) "An error occured, rolling back..." >> $logPath
			error=$(echo "$postID" | awk '/<p>Error/')
			echo "ERROR: $error" >> $logPath
			rollback
			closingSelection=$(osascript << EOF
			with timeout of 60000 seconds
			tell application "System Events" to button returned of (display dialog "Due to an error the script has been cancelled. Anything that has already been created will be deleted.
			
Click View Logs to view more information" with title "$version" buttons {"Close","View Logs"} default button 2)
			end timeout
EOF
)

			if [[ "$closingSelection" == "View Logs" ]]; then
				open -a TextEdit.app "$logPath"
				exit 0
			fi
			exit 0
	fi
	
	echo $(date) "$object created with ID number $postIDFormatted" >> $logPath
}

###########################################
# BEGINNING MESSAGE AND VARIABLE COLLECTION
###########################################

#Prompt the user with the prerequisites needed to run this script successfully and allow them to quit if they're not ready. If they quit, script will exit 0 and notate in logs

#Create Log File and overwrite previous log files
echo "###################
# JAMF PROVISIONER
###################
" > $logPath
echo $(date) "Jamf Provisioner initiated, prompting user to make sure dependencies are in place..." >> $logPath

initialAnswer=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to button returned of (display dialog "Welcome to The Jamf Provisioner!
_______________________________________

This script will create a full macOS provisioning process within your Jamf Pro Server. The process will take care of downloading and staging the latest version of the Install macOS app on computers in your fleet and then when you need to wipe computers for turnover, it'll be a simple push of a button from Self Service for your IT team. When it's finished, your Jamf Pro Server will have:

- A new Provisioning category if you don't already have one
- A computer extension attribute that will report what version of the Install macOS app is currently staged on each computer
- A smart group to report which computers have the latest version of the Install macOS app staged
- A smart group to idently computers running macOS 10.15 or later since this process will only work on those machines and also do not have the latest version of the installer staged
- The three scripts that the provisioning process will use
- The three policies to deploy those scripts

When finished, the first policy will not be enabled, but the script will prompt you and ask if you would like to enable it and if so how many computers it will affect. If you would rather test the workflow first, you can easily change the TARGET of the first policy's scope to a testing device or group of testing devices and then when you're ready just change it back.

Finally, the last policy will not have a scope configured. It is recommended that you target the Smart Group named \"Provisioning: Targets for Policy 3\" and then use Limitations and Exclusions to refine exactly WHO will be able to reset the computer.

To continue, you will be prompted to enter the URL of your Jamf Pro Server as well as the username and password of an admin account. Please view the README on github to see the minimum necessary privileges needed for this account." with title "$version" buttons {"Quit", "Proceed"} default button 2)
end timeout
EOF
)

#If the user clicks quit, stop the script immediately
if [[ "$initialAnswer" == "Quit" ]]; then
	echo $(date) "User chose to quit session, terminating..." >> $logPath
	exit 0
	fi
	
#Prompt the user for the URL of their Jamf Pro server
jamfProURL=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to text returned of (display dialog "Please enter the URL of your Jamf Pro server" default answer "ex. https://my.jamf.pro" with title "$version" buttons {"OK"} default button 1)
end timeout
EOF
)
echo $(date) "Jamf Pro Server: $jamfProURL" >> $logPath

echo "
####################
# ACCOUNT VALIDATION 
####################
" >> $logPath
#
# The admin account for Jamf Pro must have AT LEAST the following Privileges:
# READ on Jamf Pro User Accounts and Groups (This will just be used to verify your account's permissions)
# READ on Sites
# CREATE/READ on Categories
# CREATE/DELETE on Computer Extension Attributes
# CREATE/DELETE on Scripts
# CREATE/READ/DELETE on Smart Computer Groups
# CREATE/UPDATE/DELETE on Policies
#
# After proceeding, first prompt the user to enter admin credentials for their Jamf Pro server
adminUser=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to text returned of (display dialog "Please enter the username of an ADMIN for your Jamf Pro server at $jamfProURL" default answer "" with title "$version" buttons {"OK"} default button 1)
end timeout
EOF
)
echo $(date) "Jamf Pro admin account to be used: $adminUser" >> $logPath

# Prompt for their admin password with hidden input
adminPass=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to text returned of (display dialog "Please enter the password for admin user $adminUser for your Jamf Pro server at $jamfProURL" default answer "" with title "$version" buttons {"OK"} default button 1 with hidden answer)
end timeout
EOF
)

"/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper" -windowType utility -title "Authenticating..." -description "Testing your credentials and privileges, please stand by..." -alignDescription center &

# The script will now verify the user's account has at least the minimum privileges
echo $(date) "Checking to see if admin user $adminUser has the correct privileges..." >> $logPath
adminRecord=$(curl -su $adminUser:$adminPass $jamfProURL/JSSResource/accounts/username/$adminUser -H "Accept: text/xml" -X GET)
adminPrivileges=$(echo $adminRecord | xmllint --xpath '/account/privileges/jss_objects' -)

# Testing user's privileges to see if the necessary ones exist
if [[ $adminPrivileges == *"Create Computer Extension Attributes"* ]] && [[ $adminPrivileges == *"Delete Computer Extension Attributes"* ]] && [[ $adminPrivileges == *"Read Accounts"* ]] && [[ $adminPrivileges == *"Create Smart Computer Groups"* ]] && [[ $adminPrivileges == *"Read Smart Computer Groups"* ]] && [[ $adminPrivileges == *"Delete Smart Computer Groups"* ]] && [[ $adminPrivileges == *"Read Sites"* ]] && [[ $adminPrivileges == *"Create Categories"* ]] && [[ $adminPrivileges == *"Read Categories"* ]] && [[ $adminPrivileges == *"Create Scripts"* ]] && [[ $adminPrivileges == *"Delete Scripts"* ]] && [[ $adminPrivileges == *"Create Policies"* ]] && [[ $adminPrivileges == *"Update Policies"* ]] && [[ $adminPrivileges == *"Delete Policies"* ]]; then
	
	#Admin account has the necessary privileges needed, awesome!
	echo $(date) "Admin user $adminUser has all of the privileges necessary, continuing on..." >> $logPath
	else 
		echo $(date) "The admin user credentials that were entered do not meet all of the privelege requirements. Please log into Jamf Pro and give the account the following privileges:
	-READ on Jamf Pro User Accounts and Groups (This will just be used to verify your account's permissions)
	-READ on Sites
	-CREATE/READ on Categories
	-CREATE/DELETE on Computer Extension Attributes
	-CREATE/DELETE on Scripts
	-CREATE/READ/DELETE on Smart Computer Groups
	-CREATE/UPDATE/DELETE on Policies
	Exiting script." >> $logPath
	
	#Inform the user that the account does not have proper privileges
	# Kill the Jamf Helper prompt that's telling them to wait
	pkill jamfHelper

	osascript << EOF
	with timeout of 60000 seconds
	tell application "System Events" to display dialog "Your admin account does not have the correct privileges. Please log into Jamf Pro and give the account the following permissions:

	-READ on Jamf Pro User Accounts and Groups (This will just be used to verify your account's permissions)
	-READ on Sites
	-CREATE/READ on Categories
	-CREATE/DELETE on Computer Extension Attributes
	-CREATE/DELETE on Scripts
	-CREATE/READ/DELETE on Smart Computer Groups
	-CREATE/UPDATE/DELETE on Policies" with title "$version" buttons {"OK"} default button 1
	end timeout
EOF
	exit 0
	fi

echo $(date) "Admin account check finished. Continuing on with Site Check...

################################
# CHECK IF SITES ARE CONFIGURED
################################
" >> $logPath
# Next we will check and see if the user's server has sites configured and if so we will
# prompt the user to choose which site to create the workflow in

echo "$(date) Checking for sites..." >> $logPath

#Get the results of the sites endpoint
sites=$(curl -su $adminUser:$adminPass $jamfProURL/JSSResource/sites -H "Accept: text/xml" -X GET)

#Parse the xml for the size of the sites endpoint
siteCount=$(echo "$sites" | xmllint --xpath '/sites/size/text()' -)

# Kill the Jamf Helper prompt that's telling them to wait
pkill jamfHelper

# Switch: If there are no sites, move on, if there are sites configured, prompt the user to see which one
# they would like to create the workflow in
case $siteCount in

	"0")
	site=""
	echo "No sites configured on server $jamfProURL, moving on..." >> $logPath
	;;
	
	*)
	echo "$(date) | $siteCount site(s) configured. Prompting user to select which one they want to use..." >> $logPath
	
	#Grab the name of each site in the server and save to an array
	for index in $(seq 1 $siteCount); do
		siteArray+=( "$(echo "$sites" | xmllint --xpath "/sites/site[$index]/name/text()" -)" )
		done
	
	#Create a temporary index to reference the containers in the array
	siteIndex=$(($siteCount-1))
	
	#Build out the list for the Apple Script prompt
	for i in $(seq 0 $siteIndex); do
		siteList=$(echo "$siteList, \"${siteArray[$i]}\"")
		done
	
	#Prompt user to select a site from the list
	site=$(osascript << EOF
	with timeout of 60000 seconds
	tell application "System Events" to activate
	tell application "System Events" to choose from list {$siteList} with prompt "It looks like your Jamf Pro server has sites configured. You can assign the provisioning workflow to a specific site or leave them unassigned. Which site would you like to configure these in? (If you don't want them associated with a site, just hit cancel to continue on with the script)"
	end timeout
EOF
)
	if [[ "$site" == "false" ]]; then
		site=""
		echo "$(date) User chose not to put content in a site..." >> $logPath
		else
			echo "$(date) User selected $site. The Jamf Provisioner workflow will be assigned to this site..." >> $logPath
			fi
	;;
esac

echo $(date) "Site check finished. Continuing on with building of XML...

################
# BUILD XML DATA
################
" >> $logPath

echo $(date) "Packing up Extension Attribute XML Data..." >> $logPath

eaXML=$(cat << "EOF"
<computer_extension_attribute>
	<name>Provisioning: macOS Installer Version</name>
	<enabled>true</enabled>
	<description>Created by Jamf Provisioner. This will print out the version number of the current "Install macOS" application on the computer staged in /private/var/macOSInstaller. If it reports back "Not Installed" that means the app has not yet been staged on that computer.</description>
	<data_type>String</data_type>
	<input_type>
		<type>script</type>
		<platform>Mac</platform>
		<script>#!/bin/bash&#13;
&#13;
if [[ ! -f /private/var/macOSInstaller/installerVersion.txt ]]; then&#13;
echo "&lt;result&gt;Not Installed&lt;/result&gt;"&#13;
else&#13;
echo "&lt;result&gt;$(cat /private/var/macOSInstaller/installerVersion.txt)&lt;/result&gt;"&#13;
fi&#13;
&#13;
</script>
	</input_type>
	<inventory_display>Operating System</inventory_display>
	<recon_display>Extension Attributes</recon_display>
</computer_extension_attribute>
EOF
)

echo $(date) "Packing up Script 1 XML Data..." >> $logPath
scriptContentsOne=$(cat << "EOF"
#!/bin/sh

#######################################################################################
#
#	MIT License
#
#	Copyright (c) 2020 Jamf Open Source Community
#
#	Permission is hereby granted, free of charge, to any person obtaining a copy
#	of this software and associated documentation files (the "Software"), to deal
#	in the Software without restriction, including without limitation the rights
#	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#	copies of the Software, and to permit persons to whom the Software is
#	furnished to do so, subject to the following conditions:
#
#	The above copyright notice and this permission notice shall be included in all
#	copies or substantial portions of the Software.
#
#	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#	SOFTWARE.
#
###########################################################################################

echo "Checking to see if macOS installer exists"
count=$(ls /private/var/macOSInstaller | grep -c "Install macOS")

#If there are older versions of Install macOS, delete it
if [[ "$count" > 0 ]]; then
	echo "Deleting any previous macOS installers"
	rm -rf /Applications/Install\ macOS\ *.app
	fi

exit 0
EOF
)

#Encode script contents in bas64 to preserve formatting
scriptContentsOneEncoded=$(echo "$scriptContentsOne" | base64)

#Finish XML
scriptOneXML="<script>
	<name>Provisioning 1 Installer Cleanup</name>
	<category>Provisioning</category>
	<filename>Provisioning 1 Installer Cleanup</filename>
	<info/>
	<notes>Created by Jamf Provisioner. This script will will be associated to the \"Provisioning 1\" policy for the purpose of removing any \"Install macOS\" apps that may already exist in the Applications folder so that the subsequent script grabs the correct version.</notes>
	<priority>Before</priority>
	<parameters/>
	<os_requirements/>
	<script_contents_encoded>$scriptContentsOneEncoded</script_contents_encoded>
</script>"

echo $(date) "Packing up Script 2 XML Data..." >> $logPath
scriptContentsTwo=$(cat << "EOF"
#!/bin/sh

########################################################################################################
#
#	MIT License
#
#	Copyright (c) 2020 Jamf Open Source Community
#
#	Permission is hereby granted, free of charge, to any person obtaining a copy
#	of this software and associated documentation files (the "Software"), to deal
#	in the Software without restriction, including without limitation the rights
#	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#	copies of the Software, and to permit persons to whom the Software is
#	furnished to do so, subject to the following conditions:
#
#	The above copyright notice and this permission notice shall be included in all
#	copies or substantial portions of the Software.
#
#	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#	SOFTWARE.
#
####################################################################################################

#If the installer app isn't there, exit with a failure so the policy can try again tomorrow
if (ls /Applications | grep "Install macOS"); then
	echo "The installer app exists, continuing on..."
	else
		echo "The installer app either didn't download successfully or it got deleted before this policy could run. Ending..."
		exit 1
fi

#If the macOSInstaller directory does not exist in /private/var, create it
if [[ ! -d /private/var/macOSInstaller ]]; then
	echo "Directory does not exist, creating..."
	mkdir -p /private/var/macOSInstaller
	fi

#If there's an older version of the DMG, delete it
if [[ -f /private/var/macOSInstaller/InstallMacOS.dmg ]]; then
	echo "Previous dmg file exists, deleting..."
	rm -rf /private/var/macOSInstaller/InstallMacOS.dmg
	fi 

#Move the installer app from Applications to /private/var/macOSInstaller
echo "Moving installer..."
mv -f /Applications/Install\ macOS\ *.app /private/var/macOSInstaller

#Save the version number of the installer app to a text file for the extension attribute to read
echo "Saving version to file..."
installerOSVersion=$(/usr/libexec/PlistBuddy -c "Print Payload\ Image\ Info:version" /private/var/macOSInstaller/Install\ macOS\ *.app/Contents/SharedSupport/InstallInfo.plist)
echo "$installerOSVersion" > /private/var/macOSInstaller/installerVersion.txt

#Move to staging folder
cd /private/var/macOSInstaller

#Package up the installer app into a DMG
echo "Creating DMG of Installer..."
hdiutil create -fs HFS+ -srcfolder /private/var/macOSInstaller/Install\ macOS\ *.app -volname "InstallMacOS" "InstallMacOS.dmg"

#Delete the original to save space
echo "Deleting original..."
rm -rf /private/var/macOSInstaller/Install\ macOS\ *.app
EOF
)
#Encode script contents in bas64 to preserve formatting
scriptContentsTwoEncoded=$(echo "$scriptContentsTwo" | base64)

scriptTwoXML="
<script>
	<name>Provisioning 2 Stage macOS Installer</name>
	<category>Provisioning</category>
	<filename>Provisioning 2 Stage macOS Installer</filename>
	<info/>
	<notes>Created by Jamf Provisioner. This script will run in the \"Provisioning 2\" policy. After the \"Provisioning 1\" policy successfully downloads the latest version of the \"Install macOS\" app, this script will be immediately run to move the app to /private/var/macOSInstaller, save the version number in a text file for the extension attribute to read, and then package it up into a DMG. If any previous versions exist, this script will delete those first.</notes>
	<priority>Before</priority>
	<parameters/>
	<os_requirements/>
	<script_contents_encoded>$scriptContentsTwoEncoded</script_contents_encoded>
</script>"

echo $(date) "Packing up Script 3 XML Data..." >> $logPath

scriptContentsThree=$(cat << "EOF"
#!/bin/sh

########################################################################################################
#
#	MIT License
#
#	Copyright (c) 2020 Jamf Open Source Community
#
#	Permission is hereby granted, free of charge, to any person obtaining a copy
#	of this software and associated documentation files (the "Software"), to deal
#	in the Software without restriction, including without limitation the rights
#	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#	copies of the Software, and to permit persons to whom the Software is
#	furnished to do so, subject to the following conditions:
#
#	The above copyright notice and this permission notice shall be included in all
#	copies or substantial portions of the Software.
#
#	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#	SOFTWARE.
#
####################################################################################################

#Mount the DMG containing the staged macOS installer app
hdiutil attach -nobrowse /private/var/macOSInstaller/InstallMacOS.dmg

#Get the version of macOS on the target version
macOSVersion=$(/usr/bin/sw_vers -productVersion)
echo "macOS Version $macOSVersion"

#Get version of the staged macOS Installer app
installerOSVersion=$(/usr/libexec/PlistBuddy -c "Print Payload\ Image\ Info:version" /Volumes/InstallMacOS/Install\ macOS\ *.app/Contents/SharedSupport/InstallInfo.plist)
echo "Installer Version $installerOSVersion"

#If the installer and target computer are on different versions, the computer must first be upgraded
if [[ "$macOSVersion" != "$installerOSVersion" ]]; then
echo "Preparing to upgrade the computer. This may take a little while."

#Get the exact name of the current installer (Yay future proofing!)
installerName=$(ls /Volumes/InstallMacOS | grep "Install macOS")
echo "Running from path /Volumes/InstallMacOS/$installerName"

#Launch a full screen Jamf Helper window to prevent the user from making any further changes to their computer
"/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper" -windowType fs -title "macOS Upgrade" -heading "Starting..." -description "The upgrade process has started. It will take about 10-15 minutes for the beginning processes to finish and then your computer will automatically restart." -icon /Volumes/InstallMacOS/Install\ macOS\ *.app/Contents/Resources/DarkProductPageIcon.icns -timeout 900 -countdown -countdownPrompt "Computer will restart in approximately: " -alignCountdown center &
jamfHelperPID=$!

#Run upgrade via the startosinstall binary
/usr/bin/nohup /Volumes/InstallMacOS/"$installerName"/Contents/Resources/startosinstall \
--agreetolicense \
--forcequitapps \
--pidtosignal $jamfHelperPID &

exit
fi

#If the versions match, initiate Erase-Install
echo "Preparing to erase the computer, this may take a little while..."

#Get the exact name of the current installer (Yay future proofing!)
installerName=$(ls /Volumes/InstallMacOS | grep "Install macOS")
echo "Running from path /Volumes/InstallMacOS/$installerName"

#Launch a full screen Jamf Helper window to prevent the user from making any further changes to their computer
"/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper" -windowType fs -title "macOS Wipe/Install" -heading "Starting..." -description "The wipe/install process has started. It will take about 10-15 minutes for the beginning processes to finish and then your computer will automatically restart." -icon /Volumes/InstallMacOS/Install\ macOS\ *.app/Contents/Resources/DarkProductPageIcon.icns -timeout 900 -countdown -countdownPrompt "Computer will restart in approximately: " -alignCountdown center &
jamfHelperPID=$!

#Initiate erase-install via the startosinstall binary
/usr/bin/nohup /Volumes/InstallMacOS/"$installerName"/Contents/Resources/startosinstall \
--eraseinstall \
--newvolumename "Macintosh HD" \
--agreetolicense \
--forcequitapps \
--pidtosignal $jamfHelperPID &

exit 0
EOF
)

#Encode script contents in bas64 to preserve formatting
scriptContentsThreeEncoded=$(echo "$scriptContentsThree" | base64)

scriptThreeXML="
<script>
	<name>Provisioning 3 Reset Computer</name>
	<category>Provisioning</category>
	<filename>Provisioning 3 Reset Computer</filename>
	<info/>
	<notes>Created by Jamf Provisioner. This script will be associated with the Provisioning 3 policy that will be made available in Self Service. It is recommended that you scope that policy only to users who should be able to wipe and reprovision their devices. When run this script will first check to make sure that the \"Install macOS\" app and the target computer are both on the same OS version. If so, it will initiate an erase and install process and return the computer to the Setup Assistant brand new. If not, it will initiate an upgrade. This is because in order to use the --eraseinstall flag, the version numbers must match. Once the upgrade is completed the policy can be run again and then it will wipe the machine since the version numbers match. This script also utilizes Jamf Helper to block out the screen while the installer initializes to prevent the user from accidentally breaking the process.</notes>
	<priority>Before</priority>
	<parameters/>
	<os_requirements/>
	<script_contents_encoded>$scriptContentsThreeEncoded</script_contents_encoded>
</script>"

echo $(date) "Packing up Computer Smart Group 1 XML Data..." >> $logPath
smartGroupOneXML="<computer_group>
	<name>Provisioning: Targets for Policy 3</name>
	<is_smart>true</is_smart>
	<site>
		<name>$site</name>
	</site>
	<criteria>
		<size>1</size>
		<criterion>
			<name>Provisioning: macOS Installer Version</name>
			<priority>0</priority>
			<and_or>and</and_or>
			<search_type>is</search_type>
			<value>$latestMacOS</value>
			<opening_paren>false</opening_paren>
			<closing_paren>false</closing_paren>
		</criterion>
	</criteria>
</computer_group>"

echo $(date) "Packing up Computer Smart Group 2 XML Data..." >> $logPath

smartGroupTwoXML="<computer_group>
	<name>Provisioning: Targets for Policy 1</name>
	<is_smart>true</is_smart>
	<site>
		<name>$site</name>
	</site>
	<criteria>
		<size>2</size>
		<criterion>
			<name>Computer Group</name>
			<priority>0</priority>
			<and_or>and</and_or>
			<search_type>not member of</search_type>
			<value>Provisioning: Targets for Policy 3</value>
			<opening_paren>false</opening_paren>
			<closing_paren>false</closing_paren>
		</criterion>
		<criterion>
			<name>Operating System Version</name>
			<priority>1</priority>
			<and_or>and</and_or>
			<search_type>greater than or equal</search_type>
			<value>10.15</value>
			<opening_paren>false</opening_paren>
			<closing_paren>false</closing_paren>
		</criterion>
	</criteria>
</computer_group>"

echo $(date) "Packing up Policy 1 XML Data..." >> $logPath

policyOneXML="<policy>
	<general>
		<name>Provisioning 01: Stage macOS Installer</name>
		<enabled>false</enabled>
		<trigger>CHECKIN</trigger>
		<trigger_checkin>true</trigger_checkin>
		<trigger_enrollment_complete>false</trigger_enrollment_complete>
		<trigger_login>false</trigger_login>
		<trigger_logout>false</trigger_logout>
		<trigger_network_state_changed>false</trigger_network_state_changed>
		<trigger_startup>false</trigger_startup>
		<trigger_other/>
		<frequency>Once every day</frequency>
		<location_user_only>false</location_user_only>
		<target_drive>/</target_drive>
		<offline>false</offline>
		<category>
			<name>Provisioning</name>
		</category>
		<date_time_limitations>
			<activation_date/>
			<activation_date_epoch>0</activation_date_epoch>
			<activation_date_utc/>
			<expiration_date/>
			<expiration_date_epoch>0</expiration_date_epoch>
			<expiration_date_utc/>
			<no_execute_on/>
			<no_execute_start/>
			<no_execute_end/>
		</date_time_limitations>
		<network_limitations>
			<minimum_network_connection>No Minimum</minimum_network_connection>
			<any_ip_address>true</any_ip_address>
			<network_segments/>
		</network_limitations>
		<override_default_settings>
			<target_drive>default</target_drive>
			<distribution_point/>
			<force_afp_smb>false</force_afp_smb>
			<sus>default</sus>
			<netboot_server>current</netboot_server>
		</override_default_settings>
		<network_requirements>Any</network_requirements>
		<site>
			<name>$site</name>
		</site>
	</general>
	<scope>
		<all_computers>false</all_computers>
		<computers/>
		<computer_groups>
			<computer_group>
				<name>Provisioning: Targets for Policy 1</name>
			</computer_group>
		</computer_groups>
		<buildings/>
		<departments/>
		<limit_to_users>
			<user_groups/>
		</limit_to_users>
		<limitations>
			<users/>
			<user_groups/>
			<network_segments/>
			<ibeacons/>
		</limitations>
		<exclusions>
			<computers/>
			<computer_groups/>
			<buildings/>
			<departments/>
			<users/>
			<user_groups/>
			<network_segments/>
			<ibeacons/>
		</exclusions>
	</scope>
	<self_service>
		<use_for_self_service>false</use_for_self_service>
		<self_service_display_name/>
		<install_button_text>Install</install_button_text>
		<reinstall_button_text>Reinstall</reinstall_button_text>
		<self_service_description/>
		<force_users_to_view_description>false</force_users_to_view_description>
		<self_service_icon/>
		<feature_on_main_page>false</feature_on_main_page>
		<self_service_categories/>
		<notification>false</notification>
		<notification>Self Service</notification>
		<notification_subject>Provisioning 01: Stage macOS Installer</notification_subject>
		<notification_message/>
	</self_service>
	<package_configuration>
		<packages>
			<size>0</size>
		</packages>
	</package_configuration>
	<scripts>
		<size>1</size>
		<script>
			<name>Provisioning 1 Installer Cleanup</name>
			<priority>Before</priority>
			<parameter4/>
			<parameter5/>
			<parameter6/>
			<parameter7/>
			<parameter8/>
			<parameter9/>
			<parameter10/>
			<parameter11/>
		</script>
	</scripts>
	<printers>
		<size>0</size>
		<leave_existing_default/>
	</printers>
	<dock_items>
		<size>0</size>
	</dock_items>
	<account_maintenance>
		<accounts>
			<size>0</size>
		</accounts>
		<directory_bindings>
			<size>0</size>
		</directory_bindings>
		<management_account>
			<action>doNotChange</action>
		</management_account>
	</account_maintenance>
	<reboot>
		<message>This computer will restart in 5 minutes. Please save anything you are working on and log out by choosing Log Out from the bottom of the Apple menu.</message>
		<startup_disk>Current Startup Disk</startup_disk>
		<specify_startup/>
		<no_user_logged_in>Restart if a package or update requires it</no_user_logged_in>
		<user_logged_in>Restart if a package or update requires it</user_logged_in>
		<minutes_until_reboot>5</minutes_until_reboot>
		<start_reboot_timer_immediately>false</start_reboot_timer_immediately>
		<file_vault_2_reboot>false</file_vault_2_reboot>
	</reboot>
	<maintenance>
		<recon>false</recon>
		<reset_name>false</reset_name>
		<install_all_cached_packages>false</install_all_cached_packages>
		<heal>false</heal>
		<prebindings>false</prebindings>
		<permissions>false</permissions>
		<byhost>false</byhost>
		<system_cache>false</system_cache>
		<user_cache>false</user_cache>
		<verify>false</verify>
	</maintenance>
	<files_processes>
		<search_by_path/>
		<delete_file>false</delete_file>
		<locate_file/>
		<update_locate_database>false</update_locate_database>
		<spotlight_search/>
		<search_for_process/>
		<kill_process>false</kill_process>
		<run_command>softwareupdate --fetch-full-installer; jamf policy -event moveInstaller</run_command>
	</files_processes>
	<user_interaction>
		<message_start/>
		<allow_users_to_defer>false</allow_users_to_defer>
		<allow_deferral_until_utc/>
		<message_finish/>
	</user_interaction>
	<disk_encryption>
		<action>none</action>
	</disk_encryption>
</policy>"

echo $(date) "Packing up Policy 2 XML Data..." >> $logPath

policyTwoXML="<policy>
	<general>
		<name>Provisioning 02: Move Installer</name>
		<enabled>true</enabled>
		<trigger>EVENT</trigger>
		<trigger_checkin>false</trigger_checkin>
		<trigger_enrollment_complete>false</trigger_enrollment_complete>
		<trigger_login>false</trigger_login>
		<trigger_logout>false</trigger_logout>
		<trigger_network_state_changed>false</trigger_network_state_changed>
		<trigger_startup>false</trigger_startup>
		<trigger_other>moveInstaller</trigger_other>
		<frequency>Ongoing</frequency>
		<location_user_only>false</location_user_only>
		<target_drive>/</target_drive>
		<offline>false</offline>
		<category>
			<name>Provisioning</name>
		</category>
		<date_time_limitations>
			<activation_date/>
			<activation_date_epoch>0</activation_date_epoch>
			<activation_date_utc/>
			<expiration_date/>
			<expiration_date_epoch>0</expiration_date_epoch>
			<expiration_date_utc/>
			<no_execute_on/>
			<no_execute_start/>
			<no_execute_end/>
		</date_time_limitations>
		<network_limitations>
			<minimum_network_connection>No Minimum</minimum_network_connection>
			<any_ip_address>true</any_ip_address>
			<network_segments/>
		</network_limitations>
		<override_default_settings>
			<target_drive>default</target_drive>
			<distribution_point/>
			<force_afp_smb>false</force_afp_smb>
			<sus>default</sus>
			<netboot_server>current</netboot_server>
		</override_default_settings>
		<network_requirements>Any</network_requirements>
		<site>
			<name>$site</name>
		</site>
	</general>
	<scope>
		<all_computers>true</all_computers>
		<computers/>
		<computer_groups/>
		<buildings/>
		<departments/>
		<limit_to_users>
			<user_groups/>
		</limit_to_users>
		<limitations>
			<users/>
			<user_groups/>
			<network_segments/>
			<ibeacons/>
		</limitations>
		<exclusions>
			<computers/>
			<computer_groups/>
			<buildings/>
			<departments/>
			<users/>
			<user_groups/>
			<network_segments/>
			<ibeacons/>
		</exclusions>
	</scope>
	<self_service>
		<use_for_self_service>false</use_for_self_service>
		<self_service_display_name/>
		<install_button_text>Install</install_button_text>
		<reinstall_button_text>Reinstall</reinstall_button_text>
		<self_service_description/>
		<force_users_to_view_description>false</force_users_to_view_description>
		<self_service_icon/>
		<feature_on_main_page>false</feature_on_main_page>
		<self_service_categories/>
		<notification>false</notification>
		<notification>Self Service</notification>
		<notification_subject>Provisioning 02: Move Installer</notification_subject>
		<notification_message/>
	</self_service>
	<package_configuration>
		<packages>
			<size>0</size>
		</packages>
	</package_configuration>
	<scripts>
		<size>1</size>
		<script>
			<name>Provisioning 2 Stage macOS Installer</name>
			<priority>Before</priority>
			<parameter4/>
			<parameter5/>
			<parameter6/>
			<parameter7/>
			<parameter8/>
			<parameter9/>
			<parameter10/>
			<parameter11/>
		</script>
	</scripts>
	<printers>
		<size>0</size>
		<leave_existing_default/>
	</printers>
	<dock_items>
		<size>0</size>
	</dock_items>
	<account_maintenance>
		<accounts>
			<size>0</size>
		</accounts>
		<directory_bindings>
			<size>0</size>
		</directory_bindings>
		<management_account>
			<action>doNotChange</action>
		</management_account>
	</account_maintenance>
	<reboot>
		<message>This computer will restart in 5 minutes. Please save anything you are working on and log out by choosing Log Out from the bottom of the Apple menu.</message>
		<startup_disk>Current Startup Disk</startup_disk>
		<specify_startup/>
		<no_user_logged_in>Restart if a package or update requires it</no_user_logged_in>
		<user_logged_in>Restart if a package or update requires it</user_logged_in>
		<minutes_until_reboot>5</minutes_until_reboot>
		<start_reboot_timer_immediately>false</start_reboot_timer_immediately>
		<file_vault_2_reboot>false</file_vault_2_reboot>
	</reboot>
	<maintenance>
		<recon>true</recon>
		<reset_name>false</reset_name>
		<install_all_cached_packages>false</install_all_cached_packages>
		<heal>false</heal>
		<prebindings>false</prebindings>
		<permissions>false</permissions>
		<byhost>false</byhost>
		<system_cache>false</system_cache>
		<user_cache>false</user_cache>
		<verify>false</verify>
	</maintenance>
	<files_processes>
		<search_by_path/>
		<delete_file>false</delete_file>
		<locate_file/>
		<update_locate_database>false</update_locate_database>
		<spotlight_search/>
		<search_for_process/>
		<kill_process>false</kill_process>
		<run_command/>
	</files_processes>
	<user_interaction>
		<message_start/>
		<allow_users_to_defer>false</allow_users_to_defer>
		<allow_deferral_until_utc/>
		<message_finish/>
	</user_interaction>
	<disk_encryption>
		<action>none</action>
	</disk_encryption>
</policy>"

echo $(date) "Packing up Policy 3 XML Data..." >> $logPath

policyThreeXML="<policy>
	<general>
		<name>Provisioning 03: Reset Computer</name>
		<enabled>true</enabled>
		<trigger>EVENT</trigger>
		<trigger_checkin>false</trigger_checkin>
		<trigger_enrollment_complete>false</trigger_enrollment_complete>
		<trigger_login>false</trigger_login>
		<trigger_logout>false</trigger_logout>
		<trigger_network_state_changed>false</trigger_network_state_changed>
		<trigger_startup>false</trigger_startup>
		<trigger_other>resetComputer</trigger_other>
		<frequency>Ongoing</frequency>
		<location_user_only>false</location_user_only>
		<target_drive>/</target_drive>
		<offline>false</offline>
		<category>
			<name>Provisioning</name>
		</category>
		<date_time_limitations>
			<activation_date/>
			<activation_date_epoch>0</activation_date_epoch>
			<activation_date_utc/>
			<expiration_date/>
			<expiration_date_epoch>0</expiration_date_epoch>
			<expiration_date_utc/>
			<no_execute_on/>
			<no_execute_start/>
			<no_execute_end/>
		</date_time_limitations>
		<network_limitations>
			<minimum_network_connection>No Minimum</minimum_network_connection>
			<any_ip_address>true</any_ip_address>
			<network_segments/>
		</network_limitations>
		<override_default_settings>
			<target_drive>default</target_drive>
			<distribution_point/>
			<force_afp_smb>false</force_afp_smb>
			<sus>default</sus>
			<netboot_server>current</netboot_server>
		</override_default_settings>
		<network_requirements>Any</network_requirements>
		<site>
			<name>$site</name>
		</site>
	</general>
	<scope>
		<all_computers>false</all_computers>
		<computers/>
		<computer_groups/>
		<buildings/>
		<departments/>
		<limit_to_users>
			<user_groups/>
		</limit_to_users>
		<limitations>
			<users/>
			<user_groups/>
			<network_segments/>
			<ibeacons/>
		</limitations>
		<exclusions>
			<computers/>
			<computer_groups/>
			<buildings/>
			<departments/>
			<users/>
			<user_groups/>
			<network_segments/>
			<ibeacons/>
		</exclusions>
	</scope>
	<self_service>
		<use_for_self_service>true</use_for_self_service>
		<self_service_display_name>Provisioner: Reset Computer</self_service_display_name>
		<install_button_text>Reset</install_button_text>
		<reinstall_button_text>Reset</reinstall_button_text>
		<self_service_description>This will initiate a process to begin a full wipe of this computer. Please make sure you have backed up all data before proceeding. If this computer isn't up to date, this will first upgrade the machine. Once upgraded, return here and re-run this policy to finish the reset.</self_service_description>
		<force_users_to_view_description>true</force_users_to_view_description>
		<self_service_icon>
		</self_service_icon>
		<feature_on_main_page>false</feature_on_main_page>
		<self_service_categories>
			<category>
				<name>Provisioning</name>
				<display_in>true</display_in>
				<feature_in>false</feature_in>
			</category>
		</self_service_categories>
		<notification>false</notification>
		<notification>Self Service</notification>
		<notification_subject>Upgrade/Erase-Install</notification_subject>
		<notification_message/>
	</self_service>
	<package_configuration>
		<packages>
			<size>0</size>
		</packages>
	</package_configuration>
	<scripts>
		<size>1</size>
		<script>
			<name>Provisioning 3 Reset Computer</name>
			<priority>Before</priority>
			<parameter4/>
			<parameter5/>
			<parameter6/>
			<parameter7/>
			<parameter8/>
			<parameter9/>
			<parameter10/>
			<parameter11/>
		</script>
	</scripts>
	<printers>
		<size>0</size>
		<leave_existing_default/>
	</printers>
	<dock_items>
		<size>0</size>
	</dock_items>
	<account_maintenance>
		<accounts>
			<size>0</size>
		</accounts>
		<directory_bindings>
			<size>0</size>
		</directory_bindings>
		<management_account>
			<action>doNotChange</action>
		</management_account>
	</account_maintenance>
	<reboot>
		<message>This computer will restart in 5 minutes. Please save anything you are working on and log out by choosing Log Out from the bottom of the Apple menu.</message>
		<startup_disk>Current Startup Disk</startup_disk>
		<specify_startup/>
		<no_user_logged_in>Restart if a package or update requires it</no_user_logged_in>
		<user_logged_in>Restart if a package or update requires it</user_logged_in>
		<minutes_until_reboot>5</minutes_until_reboot>
		<start_reboot_timer_immediately>false</start_reboot_timer_immediately>
		<file_vault_2_reboot>false</file_vault_2_reboot>
	</reboot>
	<maintenance>
		<recon>false</recon>
		<reset_name>false</reset_name>
		<install_all_cached_packages>false</install_all_cached_packages>
		<heal>false</heal>
		<prebindings>false</prebindings>
		<permissions>false</permissions>
		<byhost>false</byhost>
		<system_cache>false</system_cache>
		<user_cache>false</user_cache>
		<verify>false</verify>
	</maintenance>
	<files_processes>
		<search_by_path/>
		<delete_file>false</delete_file>
		<locate_file/>
		<update_locate_database>false</update_locate_database>
		<spotlight_search/>
		<search_for_process/>
		<kill_process>false</kill_process>
		<run_command/>
	</files_processes>
	<user_interaction>
		<message_start/>
		<allow_users_to_defer>false</allow_users_to_defer>
		<allow_deferral_until_utc/>
		<message_finish/>
	</user_interaction>
	<disk_encryption>
		<action>none</action>
	</disk_encryption>
</policy>"

finalConfirmation=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to button returned of (display dialog "Everything is ready to go!
Click Proceed to continue on with the creation of assets in Jamf Pro.

If you're not ready to continue, click Quit and start the script again when you're ready." with title "$version" buttons {"Quit", "Proceed"} default button 2)
end timeout
EOF
)

#If the user clicks quit, stop the script immediately
if [[ "$finalConfirmation" == "Quit" ]]; then
	echo $(date) "User chose to quit session, terminating..." >> $logPath
	exit 0
	fi

echo $(date) "XML built, sending it off to Jamf...

############################
# CREATE OBJECTS IN JAMF PRO
############################
" >> $logPath

#Launch a Jamf Helper window to let the user know it's working
echo $(date) "Launching Jamf Helper to let the user know to wait..." >> $logPath
"/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper" -windowType utility -title "Constructing..." -description "Please wait while we make some Jamf magic happen..." -alignDescription center &

#Create the provisioning category if it doesn't exist
categoryTest=$(curl -su $adminUser:$adminPass $jamfProURL/JSSResource/categories -H "Accept: text/xml" -X GET)

if [[ "$categoryTest" != *"<name>Provisioning</name>"* ]]; then
	provisionerPost "categories" "<category><name>Provisioning</name></category>"
	fi

#Create extension attribute
provisionerPost "computerextensionattributes" "$eaXML"
eaID="$postIDFormatted"

#Create First Script
provisionerPost "scripts" "$scriptOneXML"
scriptOneID="$postIDFormatted"
scriptIDarray+=( "$scriptOneID" )

#Create Second Script
provisionerPost "scripts" "$scriptTwoXML"
scriptTwoID="$postIDFormatted"
scriptIDarray+=( "$scriptTwoID" )

#Create Third Script
provisionerPost "scripts" "$scriptThreeXML"
scriptThreeID="$postIDFormatted"
scriptIDarray+=( "$scriptThreeID" )

#Create First Smart Group
provisionerPost "computergroups" "$smartGroupOneXML"
smartGroupOneID="$postIDFormatted"
computerGroupIDarray+=( "$smartGroupOneID" )

#Wait a few seconds so before creating the next group since it is dependent on the first group
sleep 5

#Create Second Smart Group
provisionerPost "computergroups" "$smartGroupTwoXML"
smartGroupTwoID="$postIDFormatted"
computerGroupIDarray+=( "$smartGroupTwoID" )

#Create First Policy
provisionerPost "policies" "$policyOneXML"
policyOneID="$postIDFormatted"
policyIDarray+=( "$policyOneID" )

#Create Second Policy
provisionerPost "policies" "$policyTwoXML"
policyTwoID="$postIDFormatted"
policyIDarray+=( "$policyTwoID" )

#Create Third Policy
provisionerPost "policies" "$policyThreeXML"
policyThreeID="$postIDFormatted"
policyIDarray+=( "$policyThreeID" )

echo $(date) "Objects Created, moving on to final measures...

###################
# CHECK TARGET SIZE
###################
" >> $logPath

#Now get the size of how many computers are in scope of Policy one
targetSize=$(curl -su $adminUser:$adminPass $jamfProURL/JSSResource/computergroups/id/$smartGroupTwoID -H "Accept: text/xml" -X GET | xmllint --xpath '/computer_group/computers/size/text()' -)
echo $(date) "$targetSize computers will receive Policy 1 once it is enabled." >> $logPath

#Kill the jamf helper window that's telling the user to wait
pkill jamfHelper

#Prompt user for final decisions
enableAnswer=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to button returned of (display dialog "POLICY ENABLEMENT

All of the pieces of the Provisioner workflow have been built. Currently the first policy that kicks off the whole workflow is disabled by default.

If enabled, it will take effect on $targetSize computers at each of their respective checkins. If you'd like we can enable the policy now to kick it all off, or you can leave it disabled in case you want to temporarily change the target for testing purposes. Which would you like to do?" with title "$version" buttons {"Keep Policy Disabled", "Enable Policy"} default button 1)
end timeout
EOF
)

#If the user chooses to enable the policy, send an API call to update the enabled status of the policy
if [[ "$enableAnswer" == "Enable Policy" ]]; then
	#Enable the policy
	curl -su $adminUser:$adminPass $jamfProURL/JSSResource/policies/id/$policyOneID -H "Content-type: text/xml" -X PUT -d '<policy><general><enabled>true</enabled></general></policy>'
	echo $(date) "User chose to enable the first policy in the workflow..... policy is enabled." >> $logPath
	fi
	
createDeconstructor=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to button returned of (display dialog "DE-Constructor Script:
We can create a script on your desktop that can be used to DELETE everything that gets created today. This can be especially useful if you're only testing or creating demo enviroments that you want to nuke later and will make it easy to do so. Would you like this script to be created?" with title "$version" buttons {"Yes", "No"} default button 1)
end timeout
EOF
)

if [[ "$createDeconstructor" == "Yes" ]]; then
cat << FOE > ~/Desktop/JamfProvisionerDeconstructor.sh
#!/bin/bash

#########################################################
#	MIT License
#
#	Copyright (c) 2020 Jamf Open Source Community
#
#	Permission is hereby granted, free of charge, to any person obtaining a copy
#	of this software and associated documentation files (the "Software"), to deal
#	in the Software without restriction, including without limitation the rights
#	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#	copies of the Software, and to permit persons to whom the Software is
#	furnished to do so, subject to the following conditions:
#
#	The above copyright notice and this permission notice shall be included in all
#	copies or substantial portions of the Software.
#
#	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#	SOFTWARE.
#########################################################

#Pass down variables from original script
scriptIDarray=( ${scriptIDarray[@]} )
policyIDarray=( ${policyIDarray[@]} )
computerGroupIDarray=( ${computerGroupIDarray[@]} )
scriptSize=\${#scriptIDarray[@]}
policySize=\${#policyIDarray[@]}
computerGroupSize=\${#computerGroupIDarray[@]}
jamfProURL=$jamfProURL
eaID=$eaID
logPath=$logPath

#Prompt the user for what is about to happen
openingSelection=\$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to button returned of (display dialog "Welcome to the Jamf Provisioner DE-Constructor!
This script was created after successfully finishing the Jamf Provisioner to give you the ability to delete what was created in case you need to try again or if you were just testing or creating a demo.

This script will DELETE the extension attribute, scripts, smart groups, and policies that were created the last time you ran the Jamf Provisioner script. Would you like to continue?" with title "Jamf Provisioner DE-Constructor" buttons {"Continue","Cancel"} default button 2)
end timeout
EOF
)
if [[ \$openingSelection == "Cancel" ]]; then
	exit 0
	fi

echo "
########################
# JAMF SETUP DE-CONSTRUCTOR INITIATED
########################" >> \$logPath

adminUser=\$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to text returned of (display dialog "Please enter the username of an ADMIN for your Jamf Pro server at \$jamfProURL who has the ability to DELETE Computer Extension Attributes, Scripts, Smart Computer Groups, and Policies." default answer "" with title "Jamf Provisioner DE-Constructor" buttons {"OK"} default button 1)
end timeout
EOF
)

adminPass=\$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to text returned of (display dialog "Please enter the password for admin user \$adminUser for your Jamf Pro server at \$jamfProURL" default answer "" with title "Jamf Provisioner DE-Constructor" buttons {"OK"} default button 1 with hidden answer)
end timeout
EOF
)

#Final Confirmation
while [[ "\$confirmation" != "DELETE" ]]; do
confirmation=\$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to text returned of (display dialog "The following items will be deleted from your Jamf Pro server:

The computer extension attribute used to determine the version of the staged installer
The three scripts used in the provisioning workflow
The two smart groups used for scoping of the workflow
The three policies used to deploy the workflow

In order to proceed, please type the word DELETE into the box below.
To cancel type CANCEL." default answer "" with title "Jamf Setup DE-Constructor" buttons {"Submit"} default button 1)
end timeout
EOF
)
if [[ \$confirmation == "CANCEL" ]]; then
	echo "User canceled deconstructor session..." >> \$logPath
	exit 0
	fi
done

#Bring up a Jamf Helper window to let them know it's working
"/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper" -windowType utility -title "DE-Constructing..." -description "Please wait while we make some Jamf magic happen..." -alignDescription center &

#Start by deleting the policies
policyIndex=\$((\$policySize-1))
for i in \$(seq 0 \$policyIndex); do
	curl -su \$adminUser:\$adminPass \$jamfProURL/JSSResource/policies/id/\${policyIDarray[\$i]} -X DELETE
	echo \$(date) "Policy with ID \${policyIDarray[\$i]} deleted... " >> \$logPath
	done

#Next delete the smart groups
computerGroupIndex=\$((\$computerGroupSize-1))
for i in \$(seq \$computerGroupIndex 0); do
	curl -su \$adminUser:\$adminPass \$jamfProURL/JSSResource/computergroups/id/\${computerGroupIDarray[\$i]} -X DELETE
	echo \$(date) "Computer Group with ID \${computerGroupIDarray[\$i]} deleted... " >> \$logPath
	done
			
#Next delete the scripts
scriptIndex=\$((\$scriptSize-1))
for i in \$(seq 0 \$scriptIndex); do
	curl -su \$adminUser:\$adminPass \$jamfProURL/JSSResource/scripts/id/\${scriptIDarray[\$i]} -X DELETE
	echo \$(date) "Script with ID \${scriptIDarray[\$i]} deleted... " >> \$logPath
	done
				
#Finally, delete the extension attribute
curl -su \$adminUser:\$adminPass \$jamfProURL/JSSResource/computerextensionattributes/id/\$eaID -X DELETE
echo \$(date) "Extension attribute deleted...." >> \$logPath

pkill jamfHelper

finalButtonChoice=\$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to button returned of (display dialog "Your items have been successfully deleted from Jamf Pro! You can view the same logs that were used from the Jamf Provisioner script located at:
\$logPath" with title "Jamf Provisioner DE-Constructor" buttons {"Close","View Logs"} default button 1)
end timeout
EOF
)
if [[ "\$finalButtonChoice" == "View Logs" ]]; then
	open -a TextEdit.app "\$logPath"
	rm -f \$0
	exit 0
		else
			rm -f \$0
			exit 0
	fi
FOE
#Make the script executable
chmod 755 ~/Desktop/JamfProvisionerDeconstructor.sh
echo $(date) "Jamf Provisioner Deconstructor script created on the Desktop" >> $logPath
fi

closingSelection=$(osascript << EOF
with timeout of 60000 seconds
tell application "System Events" to button returned of (display dialog "All finished! Your Jamf Pro server should now be configured with the entire Jamf Provisioning Workflow!

Note: You might not see everything that was created right away because of your cache. If you do not see everything right away simply log out and log back in.

If you chose to enable the first policy, then the process will have already started on your machines. In the background they will download and stage the latest version of the Install macOS app to be available to use for the erase-install policy. The final thing you need to do is decide the scope for the third policy titled Provisioning 3: Reset Computer. We would suggest scoping it to the smart group we created called \"Provisioning: Targets for Policy 3\" and then limit it to an IT specific LDAP group or department using Limitations and Exclusions so that your end users can't accidentally trigger it. Or give it a custom trigger for technicians to use to manually trigger it.

For more information on final considerations, view the github page where you got this script!

For details on what all happened, you can find the logs at: 
$logPath" with title "$version" buttons {"Close","View Logs"} default button 1)
end timeout
EOF
)

echo "Everything has been successfully created! Enjoy your new Jamf Provisioning experience!

###########################################
# SUCCESS!!! BRING IN THE DANCING LOBSTERS!
###########################################
" >> $logPath

if [[ $closingSelection == "View Logs" ]]; then
	open -a TextEdit.app "$logPath"
	exit 0
	else
		exit 0
fi