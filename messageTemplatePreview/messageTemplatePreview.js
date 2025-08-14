import { LightningElement, api, wire, track } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import getTemplates from '@salesforce/apex/TemplateResolverService.getAvailableTemplates';
import resolveTemplate from '@salesforce/apex/TemplateResolverService.resolveTemplate';

import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import NAME_FIELD from '@salesforce/schema/Message_Template__c.Name';
import BODY_FIELD from '@salesforce/schema/Message_Template__c.Message_Body__c';
import VARS_FIELD from '@salesforce/schema/Message_Template__c.TemplateVariables__c';
import LOOKUPS_FIELD from '@salesforce/schema/Message_Template__c.ObjectLookups__c';

export default class MessageTemplatePreview extends LightningElement {
    @api recordId;                     // Context record (Account/Case)
    @track templateOptions = [];
    @track selectedTemplateId;
    @track selectedTemplateName;
    @track resolvedMessage;
    @track error;

    // Get recordId from EC (attributes) or standard (state)
    @wire(CurrentPageReference)
    getStateParameters(pageRef) {
        const recordIdFromState = pageRef?.state?.recordId;
        const recordIdFromAttributes = pageRef?.attributes?.recordId;
        if (!this.recordId) {
            this.recordId = recordIdFromState || recordIdFromAttributes || this.recordId;
        }
    }

    // Load templates for the picklist
    @wire(getTemplates)
    wiredTemplates({ data, error }) {
        if (data) {
            this.templateOptions = data.map(t => ({ label: t.Name, value: t.Id }));
        } else if (error) {
            this.error = 'Failed to load templates';
            // eslint-disable-next-line no-console
            console.error('Error loading templates:', error);
        }
    }

    // Pull selected Message_Template__c fields (for the “Details” section)
    @wire(getRecord, {
        recordId: '$selectedTemplateId',
        fields: [NAME_FIELD, BODY_FIELD, VARS_FIELD, LOOKUPS_FIELD]
    }) templateRecord;

    // NULL-SAFE getters (fix): guard when wire hasn’t returned yet
    get tmplName()    { return getFieldValue(this.templateRecord?.data, NAME_FIELD); }
    get tmplBody()    { return getFieldValue(this.templateRecord?.data, BODY_FIELD); }
    get tmplVars()    { return getFieldValue(this.templateRecord?.data, VARS_FIELD); }
    get tmplLookups() { return getFieldValue(this.templateRecord?.data, LOOKUPS_FIELD); }

    // When user picks a template
    handleTemplateChange(event) {
        const selectedOption = this.templateOptions.find(opt => opt.value === event.detail.value);
        this.selectedTemplateId = selectedOption?.value;
        this.selectedTemplateName = selectedOption?.label;

        // One clean debug log to show the public EC link you built
        // eslint-disable-next-line no-console
        console.log(`Template selected: ${this.selectedTemplateName} → ${this.templateLink}`);

        this.resolveTemplatePreview();
    }

    // Experience Cloud link (for show)
    get templateLink() {
        if (!this.selectedTemplateId || !this.selectedTemplateName) return null;
        const nameSlug = this.selectedTemplateName.toLowerCase().replace(/\s+/g, '-');
        return `https://orgfarm-f4625f5449-dev-ed.develop.my.site.com/message-template/${this.selectedTemplateId}/${nameSlug}`;
    }

    // Utilities
    stripHtmlTags(str) { return str ? str.replace(/<[^>]*>/g, '') : ''; }
    decodeHtmlEntities(str) {
        const txt = document.createElement('textarea');
        txt.innerHTML = str || '';
        return txt.value;
    }

    // Resolve preview via Apex
    resolveTemplatePreview() {
        if (!this.recordId || !this.selectedTemplateId) {
            this.error = 'Record ID or Template is missing.';
            return;
        }

        this.resolvedMessage = '';
        this.error = null;

        resolveTemplate({ recordId: this.recordId, templateId: this.selectedTemplateId })
            .then(result => {
                const decoded = this.decodeHtmlEntities(result.resolvedBody);
                this.resolvedMessage = this.stripHtmlTags(decoded);
            })
            .catch(error => {
                this.error = 'Could not resolve template.';
                // eslint-disable-next-line no-console
                console.error('Template resolution error:', error);
            });
    }
}
