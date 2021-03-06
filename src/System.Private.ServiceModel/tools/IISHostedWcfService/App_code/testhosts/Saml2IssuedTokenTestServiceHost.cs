﻿// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using System;
using System.Security.Cryptography.X509Certificates;
using System.ServiceModel;
using System.ServiceModel.Channels;
using System.ServiceModel.Security;
using System.IdentityModel.Tokens;

namespace WcfService
{
    [TestServiceDefinition(Schema = ServiceSchema.HTTPS, BasePath = Saml2IssuedTokenTestServiceHost.BasePath)]
    public class Saml2IssuedTokenTestServiceHost : TestServiceHostBase<IWcfService>
    {
        private const string BasePath = "Saml2IssuedToken.svc";
        private const string Saml20TokenType = "http://docs.oasis-open.org/wss/oasis-wss-saml-token-profile-1.1#SAMLV2.0";

        protected override string Address { get { return "issued-token-using-tls"; } }

        protected override Binding GetBinding()
        {
            var authorityBinding = new WSHttpBinding(SecurityMode.Transport);
            var serviceBinding = new WS2007FederationHttpBinding(WSFederationHttpSecurityMode.TransportWithMessageCredential);
            serviceBinding.Security.Message.IssuedTokenType = Saml20TokenType;
            var serverBasePathUri = BaseAddresses[0];
            var issuerUri = new Uri(serverBasePathUri, FederationSTSServiceHost.BasePath + "/" + FederationSTSServiceHost.RelativePath);
            serviceBinding.Security.Message.IssuerAddress = new EndpointAddress(issuerUri);
            serviceBinding.Security.Message.IssuerBinding = authorityBinding;
            serviceBinding.Security.Message.IssuedKeyType = SecurityKeyType.BearerKey;
            return serviceBinding;
        }

        protected override void ApplyConfiguration()
        {
            base.ApplyConfiguration();
            Credentials.ServiceCertificate.Certificate = TestHost.CertificateFromFriendlyName(StoreName.My, StoreLocation.LocalMachine, "WCF Bridge - Machine certificate generated by the CertificateManager");
            Credentials.UseIdentityConfiguration = true;
            Uri serverBasePathUri = BaseAddresses[0]; // Just in case an address isn't found for https, prevents a NRE
            foreach(var baseAddress in BaseAddresses)
            {
                if(baseAddress.Scheme == "https")
                {
                    serverBasePathUri = baseAddress;
                    break;
                }
            }

            var audienceUriBuilder = new UriBuilder(serverBasePathUri);
            audienceUriBuilder.Path = audienceUriBuilder.Path + "/" + Address; // localhost
            audienceUriBuilder.Host = "localhost"; // When IIS hosted Host was the fqdn, self hosted it's localhost
            Credentials.IdentityConfiguration.AudienceRestriction.AllowedAudienceUris.Add(audienceUriBuilder.Uri);

            audienceUriBuilder.Host = System.Net.Dns.GetHostEntry("127.0.0.1").HostName; // fqdn
            Credentials.IdentityConfiguration.AudienceRestriction.AllowedAudienceUris.Add(audienceUriBuilder.Uri);

            audienceUriBuilder.Host = Environment.MachineName; // netbios name
            Credentials.IdentityConfiguration.AudienceRestriction.AllowedAudienceUris.Add(audienceUriBuilder.Uri);

            Credentials.IdentityConfiguration.CertificateValidationMode = X509CertificateValidationMode.None;
            var issuerUri = new Uri(serverBasePathUri, FederationSTSServiceHost.BasePath + "/" + FederationSTSServiceHost.RelativePath);
            Credentials.IdentityConfiguration.IssuerNameRegistry = new CustomIssuerNameRegistry(issuerUri.ToString());
        }

        public Saml2IssuedTokenTestServiceHost(params Uri[] baseAddresses)
            : base(typeof(WcfService), baseAddresses)
        {
        }

        class CustomIssuerNameRegistry : IssuerNameRegistry
        {
            string _issuer;
            public CustomIssuerNameRegistry(string issuer)
            {
                _issuer = issuer;
            }

            public override string GetIssuerName(SecurityToken securityToken)
            {
                return _issuer;
            }
        }
    }
}
