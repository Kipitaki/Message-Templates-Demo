/**
 * TemplateResolverService
 *
 * What this does:
 * - Takes a template and a record, fills in {{VarPath}} with live Salesforce data, and returns the final message.
 * - Supports fields on the context record (Account or Case), User fields, simple relationship paths, and optional admin lookups.
 *
 * How it works (at a glance):
 * - Reads template config (body, variable list, optional lookup SOQL).
 * - Figures out the base object from the record Id.
 * - Pulls only the fields we actually need.
 * - Resolves each unique variable once, formats it, then replaces tokens in the body.
 *
 * Notes:
 * - Runs with sharing. Field-level security is not enforced here.
 * - DateTime uses the running user's timezone.
 */
public with sharing class TemplateResolverService {

    // Return type to the UI: the final body and the per-variable values used.
    public class ResolvedTemplate {
        @AuraEnabled public String resolvedBody;
        @AuraEnabled public Map<String, String> variables = new Map<String, String>();
    }

    /**
     * Resolve a template against a specific record.
     * recordId: Account or Case Id
     * templateId: Message_Template__c Id
     */
    @AuraEnabled(cacheable=true)
    public static ResolvedTemplate resolveTemplate(Id recordId, Id templateId) {
        ResolvedTemplate result = new ResolvedTemplate();

        // 1) Load template settings (body, variables, optional lookup SOQL)
        Message_Template__c template = [
            SELECT Id, Message_Body__c, TemplateVariables__c, ObjectLookups__c
            FROM Message_Template__c
            WHERE Id = :templateId
            LIMIT 1
        ];

        // 2) Identify the base object from the Id prefix (Account or Case)
        String contextObject = resolveObjectFromId(recordId);

        // 3) Parse variables
        // rawVars keeps original order for replacement
        // uniqueVars removes duplicates so we only resolve each once
        List<String> rawVars = new List<String>();
        if (!String.isBlank(template.TemplateVariables__c)) {
            List<String> tempVars = template.TemplateVariables__c.replace(' ', '').split(',');
            for (String v : tempVars) {
                if (!String.isBlank(v)) rawVars.add(v);
            }
        }
        Set<String> uniqueVars = new Set<String>(rawVars);

        // Optional admin lookups: "Label: SELECT ... WHERE ... {{ContextId}}"
        Map<String, Map<String, String>> relatedLookups = parseLookupQueries(template.ObjectLookups__c);

        // Figure out which fields to select
        Set<String> rootFields   = new Set<String>();           // fields on the base object
        Map<String, Set<String>> relatedFields = new Map<String, Set<String>>(); // single hop, e.g., Contact.FirstName
        Set<String> userFields   = new Set<String>();           // User.FirstName, etc.

        for (String var : uniqueVars) {
            if (var.startsWith('User.')) {
                userFields.add(var.substring(5));
            } else if (!var.contains('.')) {
                rootFields.add(var);
            } else {
                String[] parts = var.split('\\.');
                String rel = parts[0];
                String field = parts[1]; // single-hop select for the base query
                if (!relatedFields.containsKey(rel)) relatedFields.put(rel, new Set<String>());
                relatedFields.get(rel).add(field);
            }
        }

        // 4) Query the base record with only needed fields
        String soql = 'SELECT Id';
        for (String f : rootFields) soql += ', ' + f;
        for (String rel : relatedFields.keySet()) {
            if (rel != 'User' && !relatedLookups.containsKey(rel)) {
                for (String f : relatedFields.get(rel)) soql += ', ' + rel + '.' + f;
            }
        }
        soql += ' FROM ' + contextObject + ' WHERE Id = :recordId';
        SObject contextRecord = Database.query(soql);

        // 5) If template uses User.* fields, load only those
        User currentUser;
        if (!userFields.isEmpty()) {
            String userSoql = 'SELECT ' + String.join(new List<String>(userFields), ',') +
                              ' FROM User WHERE Id = \'' + UserInfo.getUserId() + '\'';
            currentUser = (User) Database.query(userSoql);
        }

        // 6) If admin lookups exist, run them now and keep the first row by label
        Map<String, SObject> relatedRecords = new Map<String, SObject>();
        for (String label : relatedLookups.keySet()) {
            String query = relatedLookups.get(label).get('soql')
                .replace('{{ContextId}}', '\'' + recordId + '\'');
            try {
                List<SObject> rows = Database.query(query);
                if (!rows.isEmpty()) relatedRecords.put(label, rows[0]);
            } catch (Exception e) {
                System.debug('Lookup failed for ' + label + ': ' + e.getMessage());
            }
        }

        // 7) Resolve each unique variable to a string (handles nulls and dates)
        for (String var : uniqueVars) {
            Object val;
            try {
                if (var.startsWith('User.') && currentUser != null) {
                    val = currentUser.get(var.substring(5));
                } else if (!var.contains('.')) {
                    val = contextRecord.get(var);
                } else {
                    // Dotted path: choose the source, then walk the chain
                    List<String> parts = var.split('\\.');
                    String prefix = parts[0];
                    List<String> path = new List<String>();
                    for (Integer i = 1; i < parts.size(); i++) path.add(parts[i]);

                    SObject source;
                    if (relatedRecords.containsKey(prefix)) {
                        source = relatedRecords.get(prefix);
                    } else if (prefix == contextObject || prefix == contextObject.replace('__c', '')) {
                        source = contextRecord;
                    } else {
                        source = (SObject) contextRecord.getSObject(prefix);
                    }

                    val = resolveNestedValue(source, path);
                }

                // Normalize for display
                if (val == null) {
                    result.variables.put(var, '[Missing]');
                } else if (val instanceof DateTime) {
                    result.variables.put(var, ((DateTime)val).format('MM/dd/yy hh:mm a'));
                } else if (val instanceof Date) {
                    result.variables.put(var, ((Date)val).format());
                } else {
                    result.variables.put(var, String.valueOf(val));
                }
            } catch (Exception e) {
                System.debug('Error resolving ' + var + ': ' + e.getMessage());
                result.variables.put(var, '[Error]');
            }
        }

        // 8) Replace tokens in order, so every occurrence gets filled
        result.resolvedBody = template.Message_Body__c;
        for (String var : rawVars) {
            result.resolvedBody = result.resolvedBody.replace('{{' + var + '}}', result.variables.get(var));
        }

        return result;
    }

    // Walks nested relationships to return the final field value.
    private static Object resolveNestedValue(SObject source, List<String> parts) {
        SObject current = source;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (current == null) return null;
            current = current.getSObject(parts[i]);
        }
        return current != null ? current.get(parts[parts.size() - 1]) : null;
    }

    // Parses ObjectLookups__c into label -> SOQL
    private static Map<String, Map<String, String>> parseLookupQueries(String raw) {
        Map<String, Map<String, String>> parsed = new Map<String, Map<String, String>>();
        if (String.isBlank(raw)) return parsed;

        for (String line : raw.split('\n')) {
            line = line.trim();
            if (String.isBlank(line)) continue;

            String label;
            String soql;

            if (line.contains(':')) {
                List<String> parts = line.split(':', 2);
                label = parts[0].trim();
                soql  = parts[1].trim();
            } else if (line.toLowerCase().startsWith('select')) {
                soql  = line;
                label = extractObjectFromSOQL(soql);
            } else {
                continue;
            }

            parsed.put(label, new Map<String, String>{ 'soql' => soql });
        }
        return parsed;
    }

    // Pulls the object name after FROM
    private static String extractObjectFromSOQL(String soql) {
        Integer idx = soql.toLowerCase().indexOf(' from ');
        String fromClause = soql.substring(idx + 6).trim();
        return fromClause.contains(' ') ? fromClause.substring(0, fromClause.indexOf(' ')) : fromClause;
    }

    // Maps Id prefix to base object. Extend as needed.
    private static String resolveObjectFromId(Id recordId) {
        String prefix = String.valueOf(recordId).substring(0, 3);
        if (prefix == '001') return 'Account';
        if (prefix == '500') return 'Case';
        throw new AuraHandledException('Unsupported record type: ' + recordId);
    }

    // Simple template list helper (can be filtered later)
    @AuraEnabled(cacheable=true)
    public static List<Message_Template__c> getAvailableTemplates() {
        return [
            SELECT Id, Name
            FROM Message_Template__c
            ORDER BY Name
        ];
    }
}