Message Templates Demo
Demo: Public Site – Message Resolver in Action
https://orgfarm-f4625f5449-dev-ed.develop.my.site.com/
GitHub Repo: Message-Templates-Demo
https://github.com/Kipitaki/Message-Templates-Demo

Objective
This is a proof-of-concept I built to show how Salesforce can take a predefined message template and automatically fill in the blanks with live record data. It’s a full example of Apex and Lightning Web Components working together to make messaging faster, more accurate, and a lot less manual.

Reason for Use
If you send out a lot of client updates, reminders, or onboarding messages, typing or copy-pasting the same thing over and over gets old fast—and mistakes happen. This setup lets you pick a template, pull in details from an Account or Case automatically, and preview the exact message before it’s sent. It saves time and makes sure the right info goes to the right person every time.

Elements

Apex Class – TemplateResolverService
• Takes a message template and a Salesforce record (Account or Case) and swaps out variables like {{Account.FirstName}} with actual values.
• Can pull from the current record, related records, the running user, or admin-defined lookups.
• Only queries the fields it actually needs.
• Formats values (like dates) and sends back both the final message body and a list of variables it used.
• Designed to plug into LWCs but can also be used in Flows or other Apex code.

Lightning Web Component – MessageTemplatePreview
• Loads available templates from Apex for whatever record you’re looking at.
• Lets you pick a template and see the finished message with real Salesforce data filled in.
• Calls the TemplateResolverService to do the heavy lifting.
• Cleans up the text so it’s readable (removes HTML tags, decodes entities).
• Shows errors if something goes wrong.
• Great for testing templates before you start sending them out.
<img width="432" height="654" alt="image" src="https://github.com/user-attachments/assets/b019c590-69b8-43e0-a5ef-7ce91f0a7f96" />
