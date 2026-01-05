import React, { useEffect } from 'react';
import { useHistory } from '@docusaurus/router';
import Layout from '@theme/Layout';

export default function Home(): React.ReactElement {
    const history = useHistory();

    useEffect(() => {
        history.replace('/docs/intro');
    }, [history]);

    return (
        <Layout title="Redirecting...">
            <div className="container margin-top--lg">
                <p>Redirecting to documentation...</p>
            </div>
        </Layout>
    );
}
